#!/usr/bin/env bash
set -euo pipefail

# -------- Variables (Step 2) --------
CSV_PATH="${1:-./data.csv}"
TEAMS_ROOT="/var/www/html/teams"
LOG="./provision.log"
REPORT="./report.txt"

# -------- Logging helpers (Step 2) --------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }

# -------- Root check (Step 2) --------
require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo $0 [data.csv]  (or: $0 --test-parse [data.csv])"
}

# -------- Idempotent helpers (Step 2) --------
group_safe() {
  # Linux group names often limited to 32 chars
  local g="$1"
  if ((${#g} > 32)); then
    local h
    h="$(printf '%s' "$g" | md5sum | awk '{print $1}')"
    echo "grp_${h:0:12}"
  else
    echo "$g"
  fi
}

ensure_group() {
  local g="$1"
  [[ -n "$g" ]] || return 0
  getent group "$g" >/dev/null || { log "Creating group: $g"; groupadd "$g"; }
}

ensure_dir() {
  local path="$1" owner="$2" group="$3" mode="$4"
  if [[ ! -d "$path" ]]; then
    log "Creating dir: $path"
    install -d -m "$mode" -o "$owner" -g "$group" "$path"
  else
    chown "$owner:$group" "$path"
    chmod "$mode" "$path"
  fi
}

# Minimal change: report contains "username,uid"
log_user_created() {
  local u="$1"
  echo "$u,$(id -u "$u")" >> "$REPORT"
}

# ---------------- Step 1: Data cleaning ----------------
# Output: username,firstname,lastname,section,team,expertise_list,role_list
parse_students_csv() {
  local csv="${1:?usage: parse_students_csv data.csv}"

  awk -F',' '
    function trim(s){ gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
    function lower(s){ return tolower(s) }
    function safe(s){
      s = lower(s)
      gsub(/[^a-z0-9]+/, "_", s)  # replace spaces, hyphens, etc. with _
      gsub(/^_+|_+$/, "", s)      # trim leading/trailing _
      return s
    }

    {
      # skip empty lines
      if ($0 ~ /^[ \t\r\n]*$/) next
      # skip comments starting with #
      if ($0 ~ /^[ \t]*#/) next

      # trim every column
      for (i=1; i<=NF; i++) $i = trim($i)

      # skip header row
      if (tolower($1) ~ /first/ && tolower($2) ~ /last/) next

      firstname = trim($1)
      lastname  = trim($2)
      sec_team  = trim($3)   # like: "ENSA    BDIA1"
      expertise = trim($4)
      role      = trim($5)

      # extract section + team from column 3
      n = split(sec_team, parts, /[ \t]+/)
      section = (n>=1 ? parts[1] : "")
      team    = (n>=2 ? parts[n] : parts[1])  # last token becomes team

      # normalize casing + make safe identifiers
      firstname_n = safe(firstname)
      lastname_n  = safe(lastname)
      section_n   = lower(section)
      team_n      = lower(team)

      username = firstname_n "_" lastname_n

      # ---- expertise list ----
      m = split(expertise, expParts, /[ \t]*[,;\/|][ \t]*/)
      expertise_list = ""
      for (j=1; j<=m; j++) {
        tok = safe(trim(expParts[j]))
        if (tok == "") continue
        expertise_list = (expertise_list=="" ? tok : expertise_list ";" tok)
      }
      if (expertise_list == "") expertise_list = "other"

      # ---- role list ----
      r = split(role, roleParts, /[ \t]*[,;\/|][ \t]*/)
      role_list = ""
      for (j=1; j<=r; j++) {
        tok = safe(trim(roleParts[j]))
        if (tok == "") continue
        role_list = (role_list=="" ? tok : role_list ";" tok)
      }
      if (role_list == "") role_list = "other"

      # de-duplicate
      if (seen[username]++) next

      print username "," firstname_n "," lastname_n "," section_n "," team_n "," expertise_list "," role_list
    }
  ' "$csv"
}

# ---------------- Step 3: Users + Groups + SSH ----------------

ensure_user() {
  local u="$1" primary_group="$2"

  if id "$u" &>/dev/null; then
    log "User exists: $u"
    log_user_created "$u"   # minimal change: still report u,uid
    return 1
  fi

  log "Creating user: $u (primary group: $primary_group)"
  useradd -m -s /bin/bash -g "$primary_group" "$u"
  log_user_created "$u"     # minimal change: report u,uid
  return 0
}

add_to_groups() {
  local u="$1"; shift
  local arr=()
  for g in "$@"; do [[ -n "$g" ]] && arr+=("$g"); done
  ((${#arr[@]})) || return 0
  local csv; csv="$(IFS=,; echo "${arr[*]}")"
  log "Adding $u to groups: $csv"
  usermod -aG "$csv" "$u"
}

ensure_ssh_keys() {
  local u="$1"
  local home_dir; home_dir="$(eval echo "~$u")"
  local g; g="$(id -gn "$u")"   # primary group

 ensure_dir "$home_dir/.ssh" "$u" "$g" "700"

  if [[ ! -f "$home_dir/.ssh/id_rsa" ]]; then
    log "Generating SSH key for $u"
    sudo -u "$u" ssh-keygen -t rsa -b 4096 -N "" -f "$home_dir/.ssh/id_rsa" >/dev/null
  else
    log "SSH key already exists for $u"
  fi

  chown "$u:$g" "$home_dir/.ssh/id_rsa" "$home_dir/.ssh/id_rsa.pub"
  chmod 600 "$home_dir/.ssh/id_rsa" "$home_dir/.ssh/id_rsa.pub"
  chmod 700 "$home_dir/.ssh"
}

# ---------------- Step 4: Part B — Web (Apache) automation ----------------

install_lamp_pieces() {
  log "Installing/Enabling Apache + PHP + MySQL + ACL..."
  apt-get update -y
  apt-get install -y apache2 php libapache2-mod-php mysql-server php-mysql acl

  systemctl enable --now apache2 || true
  systemctl enable --now mysql || true
}

ensure_apache_active() {
  if systemctl is-active --quiet apache2; then
    return 0
  fi
  log "Apache not active; trying to start..."
  systemctl start apache2 || {
    log "Apache failed. Check:"
    log "  sudo apache2ctl configtest"
    log "  sudo systemctl status apache2 --no-pager"
    log "  sudo journalctl -xeu apache2 --no-pager | tail -n 80"
    exit 1
  }
}

enable_userdir() {
  log "Enabling Apache userdir module..."
  a2enmod userdir >/dev/null 2>&1 || true
  ensure_apache_active
  systemctl reload apache2 || true
}

setup_personal_site() {
  local u="$1"
  local home_dir; home_dir="$(eval echo "~$u")"
  local g; g="$(id -gn "$u")"

  ensure_dir "$home_dir/public_html" "$u" "$g" "755"

  if [[ ! -f "$home_dir/public_html/index.php" ]]; then
    cat > "$home_dir/public_html/index.php" <<EOF
<?php
echo "<h1>Welcome to ${u}'s page</h1>";
?>
EOF
    chown "$u:$g" "$home_dir/public_html/index.php"
    chmod 644 "$home_dir/public_html/index.php"
  fi

  chmod 750 "$home_dir" || true

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m u:www-data:--x "$home_dir" || true
    setfacl -m u:www-data:rx  "$home_dir/public_html" || true
    log "ACL set for Apache access: ~${u}/public_html"
  else
    chmod 711 "$home_dir" || true
    chmod 755 "$home_dir/public_html" || true
    log "ACL not available; used chmod fallback for Apache access"
  fi
}

setup_team_site() {
  local team="$1"

  mkdir -p "$TEAMS_ROOT"
  chmod 755 "$TEAMS_ROOT"

  local dir="$TEAMS_ROOT/$team"

  if [[ ! -d "$dir" ]]; then
    log "Creating team site dir: $dir"
    install -d -m 2775 -o root -g "$team" "$dir"
  else
    chown root:"$team" "$dir" || true
    chmod 2775 "$dir" || true
  fi

  if [[ ! -f "$dir/index.php" ]]; then
    cat > "$dir/index.php" <<EOF
<?php
echo "<h1>Welcome to team ${team}</h1>";
?>
EOF
    chown root:"$team" "$dir/index.php"
    chmod 664 "$dir/index.php"
  fi

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -d -m g:"$team":rwx "$dir" >/dev/null 2>&1 || true
  fi
}

# ---------------- Step 5: Part C — Database automation (MySQL) ----------------

mysql_exec() {
  mysql -N -B -u root -e "$1"
}

ensure_mysql_ready() {
  log "Ensuring MySQL is running..."
  systemctl enable --now mysql >/dev/null 2>&1 || true
  systemctl start mysql >/dev/null 2>&1 || true
}

ensure_mysql_db() {
  local db="$1"
  mysql_exec "CREATE DATABASE IF NOT EXISTS \`$db\`;"
}

ensure_mysql_user() {
  local u="$1" pass="$2"
  mysql_exec "CREATE USER IF NOT EXISTS '$u'@'localhost' IDENTIFIED BY '$pass';"
  mysql_exec "ALTER USER '$u'@'localhost' IDENTIFIED BY '$pass';"
}

grant_user_db() {
  local u="$1" db="$2"
  mysql_exec "GRANT ALL PRIVILEGES ON \`$db\`.* TO '$u'@'localhost';"
  mysql_exec "FLUSH PRIVILEGES;"
}

setup_mysql_for_student() {
  local u="$1" team="$2"

  local personal_db="${u}_db"
  local team_db="${team}_db"

  # strong default password to avoid ERROR 1819
  local pass="P@ssw0rd_${u}!"

  ensure_mysql_db "$personal_db"
  ensure_mysql_db "$team_db"

  ensure_mysql_user "$u" "$pass"

  grant_user_db "$u" "$personal_db"
  grant_user_db "$u" "$team_db"

  log "MySQL ready for $u (dbs: $personal_db, $team_db)"
}

# -------- Test mode (keeps your parser output structure) --------
if [[ "${1:-}" == "--test-parse" ]]; then
  parse_students_csv "${2:-./data.csv}"
  exit 0
fi

# ---------------- Main (Step 2 + Step 3 + Step 4 + Step 5 wiring) ----------------
main() {
  require_root
  : > "$LOG"
  : > "$REPORT"
  log "Starting provisioning..."
  log "CSV_PATH=$CSV_PATH"
  log "TEAMS_ROOT=$TEAMS_ROOT"

  # Step 4 - B0: install/enable LAMP pieces + userdir
  install_lamp_pieces
  enable_userdir

  # Step 5: ensure mysql is up before DB work
  ensure_mysql_ready

  while IFS=, read -r username firstname lastname section team expertise_list role_list; do
    log "Processing: user=$username team=$team expertise_list=$expertise_list role_list=$role_list"

    # Team group (primary)
    team="$(group_safe "$team")"
    ensure_group "$team"

    # Split expertise_list / role_list (semicolon-separated)
    IFS=';' read -r -a exp_arr  <<< "$expertise_list"
    IFS=';' read -r -a role_arr <<< "$role_list"

    # Make groups safe/short + create them
    exp_groups=()
    for eg in "${exp_arr[@]}"; do
      eg="$(group_safe "$eg")"
      exp_groups+=("$eg")
      ensure_group "$eg"
    done

    role_groups=()
    for rg in "${role_arr[@]}"; do
      rg="$(group_safe "$rg")"
      role_groups+=("$rg")
      ensure_group "$rg"
    done

    # Create user (primary group = team)
    ensure_user "$username" "$team" || true

    # Add user to all groups
    add_to_groups "$username" "$team" "${exp_groups[@]}" "${role_groups[@]}"

    # SSH keys
    ensure_ssh_keys "$username"

    # Step 4 - B1: personal site
    setup_personal_site "$username"

    # Step 4 - B2: team site
    setup_team_site "$team"

    # -------- MINIMAL CHANGE: create sites for expertise and role groups too --------
    for eg in "${exp_groups[@]}"; do
      setup_team_site "$eg"
    done

    for rg in "${role_groups[@]}"; do
      setup_team_site "$rg"
    done
    # ------------------------------------------------------------------------------

    # Step 5: MySQL user + personal DB + team DB + grants
    setup_mysql_for_student "$username" "$team"

  done < <(parse_students_csv "$CSV_PATH")

  log "Done. Report saved to: $REPORT"
}

main "$@"
  