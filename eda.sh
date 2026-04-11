#!/bin/bash
# Step 1: clean + parse messy CSV into a normalized stream:
# username,firstname,lastname,section,team,expertise,role
parse_students_csv() {
  local csv="${1:?usage: parse_students_csv data.csv}"

  awk -F',' '
    function trim(s){ gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
    function lower(s){ return tolower(s) }
    function safe(s){
      s = lower(s)
      gsub(/[éè]/,"e",s)
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

      # skip header row (your header contains "first name" / "last name")
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
      # de-duplicate (your file can contain the same student twice with different casing)
      if (seen[username]++) next

      print username "," firstname_n "," lastname_n "," section_n "," team_n "," expertise_list "," role_list
    }
  ' "$csv"
}

if [[ "${1:-}" == "--test-parse" ]]; then
  parse_students_csv "./data.csv"  
  exit 0
fi


