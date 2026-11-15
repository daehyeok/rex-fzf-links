#!/bin/sh
# Tests for share/filter.awk. Run from anywhere: sh path/to/filter_test.sh
dir=$(cd "$(dirname "$0")" && pwd)
awk_prog=$dir/../share/filter.awk
t=$(mktemp -d "${TMPDIR:-/tmp}/filter_test.XXXXXX")
trap 'rm -rf "$t"' EXIT
pass=0 fail=0
eq() { # NAME GOT WANT
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fi
}
# 30 items: https://example.com/1 .. /30 (index = NR)
i=1; while [ $i -le 30 ]; do printf 'https://example.com/%d\thttps://example.com/%d\t%d\tx\n' $i $i $i; i=$((i + 1)); done > "$t/items"
run() { # OFFSET QUERY [ROWS] -> rows "index:number" on one line ("-" = unnumbered)
  LC_ALL=C Q=$2 HINT=hint awk -F '\t' -v off="$1" -v rows="${3:-}" -v more="$t/more" -v count="$t/count" -f "$awk_prog" "$t/items" |
    sed 's/\x1b\[[0-9;]*m//g' | awk -F '\t' '{ n = ($2 ~ /^ [0-9]/) ? substr($2, 2, index(substr($2, 2), " ") - 1) : "-"; printf "%s:%s ", $1, n }' | sed 's/ $//'
}

eq "offset 0 rows" "$(run 0 '')" "1:1 2:2 3:3 4:4 5:5 6:6 7:7 8:8 9:9"
eq "offset 0 header" "$(cat "$t/more")" "1-9 of 30   hint"
eq "count" "$(cat "$t/count")" "30"
eq "offset 1 renumbers" "$(run 1 '')" "2:1 3:2 4:3 5:4 6:5 7:6 8:7 9:8 10:9"
eq "offset 1 header" "$(cat "$t/more")" "2-10 of 30   hint"
eq "offset 9 rows" "$(run 9 '')" "10:1 11:2 12:3 13:4 14:5 15:6 16:7 17:8 18:9"
eq "offset 9 header" "$(cat "$t/more")" "10-18 of 30   hint"
eq "last partial window" "$(run 27 '')" "28:1 29:2 30:3"
eq "last partial header" "$(cat "$t/more")" "28-30 of 30   hint"
eq "query" "$(run 0 'com/2')" "2:1 12:2 20:3 21:4 22:5 23:6 24:7 25:8 26:9"
eq "query header" "$(cat "$t/more")" "1-9 of 12   hint"
eq "query count" "$(cat "$t/count")" "12"
eq "query offset" "$(run 9 'com/2')" "27:1 28:2 29:3"
eq "no match rows" "$(run 0 'zzz')" ""
eq "no match header" "$(cat "$t/more")" "(no match)   hint"
eq "no match count" "$(cat "$t/count")" "0"
eq "negative offset" "$(run -3 '')" "1:1 2:2 3:3 4:4 5:5 6:6 7:7 8:8 9:9"

# A taller window: top 9 numbered, the rest not
eq "rows 12" "$(run 0 '' 12)" "1:1 2:2 3:3 4:4 5:5 6:6 7:7 8:8 9:9 10:- 11:- 12:-"
eq "rows 12 header" "$(cat "$t/more")" "1-12 of 30   hint"
eq "rows 12 offset 20" "$(run 20 '' 12)" "21:1 22:2 23:3 24:4 25:5 26:6 27:7 28:8 29:9 30:-"
eq "rows 12 offset 20 header" "$(cat "$t/more")" "21-30 of 30   hint"
eq "rows 5" "$(run 3 '' 5)" "4:1 5:2 6:3 7:4 8:5"
eq "rows 5 header" "$(cat "$t/more")" "4-8 of 30   hint"
eq "unnumbered row shows label" "$(LC_ALL=C Q="" HINT=h awk -F '\t' -v off=0 -v rows=10 -v more="$t/more" -f "$awk_prog" "$t/items" | sed -n 10p | cut -f2 | perl -pe 's/\e\]8;;[^\e]*\e\\//g')" "    https://example.com/10"

# picker.sh's helper scripts, run as picker.sh writes them
helper() { # NAME -> the script body between its heredoc markers
  sed -n "/^cat > \"\$D\/$1\" <<'EOF'\$/,/^EOF\$/p" "$dir/../share/picker.sh" | sed '1d;$d'
}
export D="$t/d"; mkdir -p "$D"
helper size > "$t/size"
size() { # LINES [PREVIEW_LINES] -> the list window's rows
  echo 0 > "$D/rows"; echo 0 > "$D/off"; echo 100 > "$D/count"
  FZF_LINES=$1 FZF_PREVIEW_LINES=${2:-} FZF_POS=1 sh "$t/size" > /dev/null
  cat "$D/rows"
}
eq "size helper found" "$(head -1 "$t/size")" "#!/bin/sh"
eq "size up/down (today's)" "$(size 40 23)" "13"
eq "size side" "$(size 40 40)" "37"
eq "size side, rounded border" "$(size 40 38)" "37"
eq "size hidden" "$(size 40)" "37"
eq "size flipped to stacked" "$(size 30 17)" "9"
eq "size tiny" "$(size 6 2)" "1"
eq "size reload printed" "$(echo 0 > "$D/rows"; FZF_LINES=40 FZF_PREVIEW_LINES=40 FZF_POS=3 sh "$t/size")" "reload-sync($D/filter {q})+pos(3)"
eq "size unchanged prints nothing" "$(FZF_LINES=40 FZF_PREVIEW_LINES=40 sh "$t/size")" ""

# preview: the marked line shifted so the link shows in a narrow preview
helper at > "$D/at"; helper preview > "$D/preview"; chmod +x "$D/at" "$D/preview"
pad=$(printf '%0110d' 0 | tr 0 a) # 110 columns before the link
{ echo "before $pad"; echo "$pad https://example.com/far"; echo "short https://s.example/x"; echo "after"; } > "$D/text"
preview() { # COLUMNS FROM_END MATCH -> the preview, colours removed
  FZF_PREVIEW_COLUMNS=$1 FZF_PREVIEW_LINES=3 "$D/preview" "$2" "$3" | sed 's/\x1b\[[0-9;]*m//g'
}
far=$(preview 50 3 https://example.com/far)
eq "far link shown" "$(echo "$far" | sed -n 2p)" "> …$(printf '%0019d' 0 | tr 0 a) https://example.com/far"
eq "far link ends 4 cols from edge" "$(echo "$far" | sed -n 2p | sed 's/…/./' | awk '{ print length($0) }')" "46"
eq "other lines not shifted" "$(echo "$far" | sed -n 1p | cut -c1-10)" "  before a"
eq "short line unchanged" "$(preview 50 2 https://s.example/x | sed -n 2p)" "> short https://s.example/x"
eq "wide preview unchanged" "$(preview 200 3 https://example.com/far | sed -n 2p)" "> $pad https://example.com/far"
eq "link wider than preview starts at link" "$(preview 12 3 https://example.com/far | sed -n 2p)" "> …https://example.com/far"
eq "no columns: unchanged" "$(FZF_PREVIEW_LINES=3 "$D/preview" 3 https://example.com/far | sed 's/\x1b\[[0-9;]*m//g' | sed -n 2p)" "> $pad https://example.com/far"

# picker.sh: fzf exit code 2 pauses with version and cleans up; 1 and 130 do not pause
pbin="$t/bin"; mkdir -p "$pbin"
printf '#!/bin/sh\nexit 1\n' > "$pbin/rex"; chmod +x "$pbin/rex"
cat > "$pbin/fzf" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then
  [ -n "${FZF_VER:-}" ] && echo "$FZF_VER"
  exit "${FZF_VER_RC:-0}"
fi
if [ -n "${FZF_WANT_ARG:-}" ]; then
  found=0
  for a in "$@"; do [ "$a" = "$FZF_WANT_ARG" ] && found=1; done
  [ "$found" -eq 1 ] || exit 0
fi
cat >/dev/null
exit "${FZF_RC:-0}"
EOF
chmod +x "$pbin/fzf"
run_picker() { # MODE [FZF_OPTS] -> stdout|leftover_stdin|job_gone
  jdir="$t/job"; mkdir -p "$jdir"; : > "$jdir/job.json"
  if [ "$1" = local ]; then a1="$jdir" a2="$dir/../"; else a1="0123456789abcdef" a2=""; fi
  out=$(printf 'xy' | (
    REX_BIN_DIR="$pbin" PATH="$pbin:$PATH" sh "$dir/../share/picker.sh" \
      b1 "$pbin/rex" 1024 "$(cat "$awk_prog")" "" "${2:-}" "true" "hint" "$1" "up" "$a1" "$a2" \
      "https://a.example" "https://a.example" 1 "https://a.example"
    printf '|'; cat
  ))
  gone=no; [ ! -e "$jdir" ] && gone=yes
  [ "$1" = remote ] && rm -rf "$jdir"
  printf '%s|%s\n' "$out" "$gone"
}
r2=$(FZF_RC=2 FZF_VER="0.44.1 (debian)" run_picker local)
eq "exit 2 shows version" "$(printf '%s' "$r2" | grep -c '0.44.1 (debian)')" "1"
eq "exit 2 shows close prompt" "$(printf '%s' "$r2" | grep -c 'press any key to close')" "1"
eq "exit 2 reads one key and cleans job" "${r2##*|}" "yes"
eq "exit 2 leaves second key" "$(printf '%s' "${r2%|*}" | awk -F '|' 'END { print $NF }')" "y"

r2_nover=$(FZF_RC=2 FZF_VER_RC=1 run_picker local)
eq "exit 2 without version still prompts" "$(printf '%s' "$r2_nover" | grep -c 'press any key to close')" "1"
eq "exit 2 without version reads one key" "$(printf '%s' "${r2_nover%|*}" | awk -F '|' 'END { print $NF }')" "y"

r2_glob=$(FZF_RC=2 FZF_WANT_ARG='--bad-*' run_picker local '--bad-*')
eq "exit 2 preserves glob in fzf_opts" "$(printf '%s' "$r2_glob" | grep -c 'press any key to close')" "1"

r2_remote=$(FZF_RC=2 FZF_VER="0.40.0" run_picker remote)
eq "remote exit 2 prompts" "$(printf '%s' "$r2_remote" | grep -c 'press any key to close')" "1"
eq "remote exit 2 sends no osc2" "$(printf '%s' "$r2_remote" | grep -c 'rfl:')" "0"

r130=$(FZF_RC=130 run_picker local)
eq "exit 130 (esc) prints nothing and reads no key" "$r130" "|xy|yes"

r1=$(FZF_RC=1 run_picker local)
eq "exit 1 (no match) prints nothing and reads no key" "$r1" "|xy|yes"

printf 'filter: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
