# shellcheck shell=sh
# picker.sh: the link picker pane. Runs on the pane's host under /bin/sh,
# passed inline to `sh -c`, so the host needs no copy of the plugin.
#
# What a pick does depends on where this pane runs:
#   local   the pane is on the client: run bin/act.lua on the job file, which
#           runs the command the client prepared for that item;
#   remote  set this pane's title to "rfl:<token>:open|copy:<n>" (see
#           codes.lua) and exit; the client's dispatcher sees the title.
# A cancel does nothing (local: the job dir is removed). Either way the pane
# closes when this script exits. It prints nothing the client executes.
#
# Arguments:
#   $1 block      the pane whose text the preview shows
#   $2 rexcli     client's rex CLI path, used when `rex` isn't on PATH (local panes)
#   $3 max        bytes of scrollback the client read (preview reads the same tail)
#   $4 filter_awk the filter program (share/filter.awk)
#   $5 binds      dialog keys, one "KEY<TAB>ACTION" per line
#                 (ACTION: open copy context up down close nth:N)
#   $6 fzf_opts   extra fzf flags, word-split
#   $7 context    shell command for the full-context view (LINK_FILE,
#                 LINK_LINE, LINK_MATCH are set)
#   $8 hint       key hint shown in the header
#   $9 mode       local | remote
#   ${10} preview fzf --preview-window value (see picker.lua preview_window)
#   ${11} ${12}   local: job dir, plugin root;  remote: token, empty
#   then 4 fields per item: label, url (or empty), line counted from the
#   end of the text, text to highlight in the preview
blk=$1 rexcli=$2 max=$3 filter_awk=$4 binds=$5 fzf_opts=$6 context_cmd=$7 hint=$8 mode=$9
shift 9
preview_window=$1 arg1=$2 arg2=$3
shift 3
JOB='' ROOT='' TOKEN=''
if [ "$mode" = local ]; then JOB=$arg1 ROOT=$arg2; else TOKEN=$arg1; fi

# The local job file is single-use: act.lua removes it on a pick; the EXIT
# trap removes it after a cancel, an error, or the pane being killed.
rm_job() {
  [ "$mode" = local ] && [ -n "$JOB" ] || return 0
  rm -f "$JOB/job.json"
  rmdir "$JOB" 2>/dev/null
}

if ! command -v fzf >/dev/null 2>&1; then
  printf '\n  \033[1mfzf not found on %s\033[0m\n  PATH=%s\n\n  press any key to close\n' "$(hostname)" "$PATH"
  stty -icanon -echo min 1 2>/dev/null; dd bs=1 count=1 >/dev/null 2>&1
  rm_job
  exit 0
fi

D=$(mktemp -d "${TMPDIR:-/tmp}/rex-fzf-links.XXXXXX") || { rm_job; exit 0; }
trap 'rm -rf "$D"; rm_job' EXIT
trap 'exit 0' HUP INT TERM
export D HINT="$hint" CONTEXT_CMD="$context_cmd" MODE="$mode" JOB ROOT TOKEN SHELL=/bin/sh
printf '%s\n' "$filter_awk" > "$D/filter.awk"
while [ $# -ge 4 ]; do printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; shift 4; done > "$D/items"

# The preview's copy of the pane text: the same tail the client searched.
REX=${REX_BIN_DIR:+$REX_BIN_DIR/}rex
command -v "$REX" >/dev/null 2>&1 || REX=$rexcli
export REX
"$REX" block capture -b "$blk" --trim --unwrap 2>/dev/null | tail -c "$max" > "$D/text" || : > "$D/text"

# filter QUERY [reset]: the window of $D/rows rows at offset $D/off (0 with
# reset), as rows "INDEX<TAB>display<TAB>line-from-end<TAB>match", the top 9
# numbered; writes the header ("A-B of T" and the key hint) to $D/more and
# the match count to $D/count.
cat > "$D/filter" <<'EOF'
#!/bin/sh
[ "$2" = reset ] && echo 0 > "$D/off"
off=$(cat "$D/off" 2>/dev/null) rows=$(cat "$D/rows" 2>/dev/null)
LC_ALL=C Q=$1 awk -F '\t' -v off="${off:-0}" -v rows="${rows:-9}" -v more="$D/more" -v count="$D/count" -f "$D/filter.awk" "$D/items"
EOF
# The list is a window over the matches, as tall as fzf's list area. fzf
# can't say which rows it has scrolled to, so the picker never lets it
# scroll: the window moves instead, and its top 9 rows are renumbered.
#
# size: on fzf's start and resize, the list area's height, then a reload when
# it changed. The prompt, the separator and the header take 3 lines. A preview
# beside the list is (nearly) full height and takes no list lines; one above
# or below takes its lines plus a 1-line border; a hidden one leaves
# FZF_PREVIEW_LINES unset.
cat > "$D/size" <<'EOF'
#!/bin/sh
L=${FZF_LINES:-0} P=${FZF_PREVIEW_LINES:-0}
if [ "$P" -gt 0 ] && [ "$P" -lt $((L - 2)) ]; then h=$((L - P - 1 - 3)); else h=$((L - 3)); fi
[ "$h" -lt 1 ] && h=1
[ "$h" = "$(cat "$D/rows" 2>/dev/null)" ] && exit 0
echo "$h" > "$D/rows"
off=$(cat "$D/off" 2>/dev/null); off=${off:-0}
total=$(cat "$D/count" 2>/dev/null); total=${total:-0}
last=$((total - h)); [ "$last" -lt 0 ] && last=0
[ "$off" -gt "$last" ] && echo "$last" > "$D/off"
pos=${FZF_POS:-1}; [ "$pos" -gt "$h" ] && pos=$h
printf 'reload-sync(%s/filter {q})+pos(%d)' "$D" "$pos"
EOF
# move up|down|pgup|pgdn: the fzf action for a move: inside the window, fzf's
# own up/down; past its edge, a new offset and a reload with the highlight on
# the same row.
cat > "$D/move" <<'EOF'
#!/bin/sh
off=$(cat "$D/off" 2>/dev/null); off=${off:-0}
total=$(cat "$D/count" 2>/dev/null); total=${total:-0}
h=$(cat "$D/rows" 2>/dev/null); h=${h:-9}
pos=${FZF_POS:-1} rows=${FZF_MATCH_COUNT:-0}
last=$((total - h)); [ "$last" -lt 0 ] && last=0
case $1 in
  down)
    [ "$pos" -lt "$rows" ] && { echo down; exit 0; }
    [ "$off" -lt "$last" ] || exit 0
    off=$((off + 1)) row=$rows ;;
  up)
    [ "$pos" -gt 1 ] && { echo up; exit 0; }
    [ "$off" -gt 0 ] || exit 0
    off=$((off - 1)) row=1 ;;
  pgdn)
    new=$((off + h)); [ "$new" -gt "$last" ] && new=$last
    [ "$new" -eq "$off" ] && { echo "pos($rows)"; exit 0; }
    off=$new row=$pos ;;
  pgup)
    new=$((off - h)); [ "$new" -lt 0 ] && new=0
    [ "$new" -eq "$off" ] && { echo first; exit 0; }
    off=$new row=$pos ;;
  *) exit 0 ;;
esac
echo "$off" > "$D/off"
printf 'reload-sync(%s/filter {q})+pos(%d)' "$D" "$row"
EOF
# nth N: open the Nth visible row, if the window has one.
cat > "$D/nth" <<'EOF'
#!/bin/sh
[ "$1" -le "${FZF_MATCH_COUNT:-0}" ] || exit 0
printf 'pos(%s)+transform(%s/act open {1})' "$1" "$D"
EOF
# act open|copy INDEX: the fzf action for the highlighted row; none without a row.
cat > "$D/act" <<'EOF'
#!/bin/sh
[ -n "$2" ] || exit 0
printf 'become(%s/done %s %s)' "$D" "$1" "$2"
EOF
# done open|copy INDEX: act on the pick (see the top of this file).
cat > "$D/done" <<'EOF'
#!/bin/sh
case $1 in open|copy) ;; *) exit 0 ;; esac
if [ "$MODE" = local ]; then
  "$REX" do "${ROOT}bin/act.lua" job="$JOB" action="$1" n="$2" >/dev/null 2>"$D/err" && exit 0
  printf '\n  \033[1mCould not %s item %s:\033[0m\n  %s\n\n  press any key to close\n' "$1" "$2" "$(cat "$D/err")"
  stty -icanon -echo min 1 2>/dev/null; dd bs=1 count=1 >/dev/null 2>&1
  exit 0
fi
printf '\033]2;rfl:%s:%s:%s\007' "$TOKEN" "$1" "$2" > /dev/tty
sleep 0.3
exit 0
EOF
# at FROM_END MATCH: the text line to show: FROM_END lines from the bottom if it
# holds MATCH, else the nearest line that does.
cat > "$D/at" <<'EOF'
#!/bin/sh
awk -v fe="$1" -v m="$2" '
  { l[NR] = $0 }
  END {
    want = NR - fe + 1; best = ""
    for (i = 1; i <= NR; i++) if (index(l[i], m)) {
      d = i - want; if (d < 0) d = -d
      if (best == "" || d < bd) { best = i; bd = d }
    }
    print (best == "" ? (want > 0 ? want : 1) : best)
  }' "$D/text"
EOF
# preview FROM_END MATCH: the lines around it, the link's line marked and the link reversed.
# When the link ends past the preview's right edge, the marked line starts
# with "…" and is cut so the link ends 4 columns from the edge (or starts at
# the link when it is wider than that).
cat > "$D/preview" <<'EOF'
#!/bin/sh
at=$("$D/at" "$1" "$2")
h=${FZF_PREVIEW_LINES:-15}
awk -v at="$at" -v m="$2" -v h="$h" -v w="$(( ${FZF_PREVIEW_COLUMNS:-0} - 2 ))" '
  NR >= at - int(h / 2) && NR < at - int(h / 2) + h {
    if (NR == at) {
      k = index($0, m)
      if (k && w > 0 && k + length(m) - 1 > w) {
        s = k + length(m) - 1 - w + 6
        if (s > k) s = k
        $0 = "…" substr($0, s); k = index($0, m)
      }
      if (k) $0 = substr($0, 1, k - 1) "\033[7m" m "\033[0m" substr($0, k + length(m))
      print "\033[1;33m>\033[0m " $0
    } else print "\033[2m  " $0 "\033[0m"
  }' "$D/text"
EOF
# full FROM_END MATCH: the whole text in the context viewer; quitting returns to the picker.
cat > "$D/full" <<'EOF'
#!/bin/sh
LINK_FILE="$D/text" LINK_LINE=$("$D/at" "$1" "$2") LINK_MATCH=$2 exec /bin/sh -c "$CONTEXT_CMD"
EOF
echo 9 > "$D/rows" # until fzf reports its size
chmod +x "$D/filter" "$D/size" "$D/move" "$D/nth" "$D/act" "$D/done" "$D/at" "$D/preview" "$D/full"
"$D/filter" '' reset > /dev/null

set -f # keys and fzf options are not file patterns
set -- fzf --disabled --ansi --no-sort --no-mouse --layout=reverse --info=hidden \
  --prompt='search: ' --delimiter='\t' --with-nth=2 \
  --header="$(cat "$D/more")" \
  --preview="$D/preview {3} {4}" --preview-window="$preview_window" \
  --bind="change:reload($D/filter {q} reset)+first" \
  --bind="result:transform-header(cat $D/more)" \
  --bind="start:transform($D/size)" --bind="resize:transform($D/size)"
# fzf's own move keys go through `move` too, so they scroll the window.
for k in up ctrl-p ctrl-k; do set -- "$@" "--bind=$k:transform($D/move up)"; done
for k in down ctrl-n ctrl-j; do set -- "$@" "--bind=$k:transform($D/move down)"; done
set -- "$@" "--bind=page-up:transform($D/move pgup)" "--bind=page-down:transform($D/move pgdn)"
tab=$(printf '\t')
nl='
'
old_ifs=$IFS
IFS=$nl
for b in $binds; do
  key=${b%%"$tab"*} action=${b#*"$tab"}
  case $action in
    open) f="transform($D/act open {1})" ;;
    copy) f="transform($D/act copy {1})" ;;
    context) f="execute($D/full {3} {4})" ;;
    up) f="transform($D/move up)" ;;
    down) f="transform($D/move down)" ;;
    close) f=abort ;;
    nth:*) f="transform($D/nth ${action#nth:})" ;;
    *) continue ;;
  esac
  set -- "$@" "--bind=$key:$f"
done
IFS=$old_ifs
# shellcheck disable=SC2086 # word-splitting fzf_opts is the point
set -- "$@" $fzf_opts

rc=0
"$D/filter" '' | "$@" || rc=$?
if [ "$rc" -eq 2 ]; then
  ver=$(fzf --version 2>/dev/null || true)
  printf '\n  \033[1mfzf%s failed (requires fzf 0.46+ and valid options)\033[0m\n\n  press any key to close\n' "${ver:+ ($ver)}"
  stty -icanon -echo min 1 2>/dev/null; dd bs=1 count=1 >/dev/null 2>&1
fi
exit 0
