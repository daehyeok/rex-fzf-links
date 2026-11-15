# shellcheck shell=sh
# message.sh: a one-line message in a small floating pane. Runs on the pane's
# host under /bin/sh, passed inline to `sh -c`.
#
# Shows the message, waits up to one second for a key, then gives focus back
# to the pane the user was in (Rex doesn't do that when a floating pane closes)
# and exits, which closes the pane.
#
# Arguments: $1 message  $2 block to focus afterwards  $3 client's rex CLI path,
# used when `rex` isn't on PATH (local panes)
msg=$1 blk=$2 rexcli=$3
printf '\033[?25l %s' "$msg"
old=$(stty -g 2>/dev/null)
stty -icanon -echo min 0 time 10 2>/dev/null # read returns after 1 s or one key
dd bs=1 count=1 >/dev/null 2>&1
[ -n "$old" ] && stty "$old" 2>/dev/null
REX=${REX_BIN_DIR:+$REX_BIN_DIR/}rex
command -v "$REX" >/dev/null 2>&1 || REX=$rexcli
[ -n "$blk" ] && "$REX" focus "$blk" >/dev/null 2>&1
exit 0
