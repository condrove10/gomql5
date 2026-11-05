#!/bin/bash
# envlint.sh FILE - lint a .env-style file before anything sources it.
#
# Every assignment must be KEY=VALUE (an optional `export ` prefix is fine).
# A VALUE is safe when it is:
#   'single-quoted'           with no ' inside
#   "double-quoted"           with no $ ` \ or " inside
#   unquoted                  with none of $ ` " ' \ ; & | < > ( ) or whitespace
# Blank lines and # comments are skipped. Prints the key of an unsafe line,
# never its value (a line with no KEY= is reported by number). Exit 11 on an
# unsafe line. A missing file passes: the caller's own checks report it.
#
# Usage: bash scripts/envlint.sh .env
set -u
f=${1:-}
[ -n "$f" ] || { echo "usage: envlint.sh FILE" >&2; exit 2; }
[ -f "$f" ] || exit 0
bad=0 n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  t=${line#"${line%%[![:space:]]*}"}
  case $t in '' | '#'*) continue ;; esac
  t=${t#export }
  if [[ $t != [A-Za-z_]*=* || ${t%%=*} == *[!A-Za-z0-9_]* ]]; then
    echo "envlint: unsafe line $n (not KEY=VALUE)"
    bad=1
    continue
  fi
  key=${t%%=*}
  v=${t#*=}
  safe=1
  if [[ $v == \'*\' ]]; then
    inner=${v:1:${#v}-2}
    case $inner in *"'"*) safe=0 ;; esac
  elif [[ $v == \"*\" ]]; then
    inner=${v:1:${#v}-2}
    case $inner in *'$'* | *'`'* | *'\'* | *'"'*) safe=0 ;; esac
  else
    case $v in
      *'$'* | *'`'* | *'"'* | *"'"* | *'\'* | *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *'('* | *')'* | *[[:space:]]*) safe=0 ;;
    esac
  fi
  if [ "$safe" = 0 ]; then
    echo "envlint: unsafe value for $key (line $n)"
    bad=1
  fi
done <"$f"
exit $((bad * 11))
