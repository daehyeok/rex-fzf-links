# filter.awk: one window of the picker's list for a query. Run by picker.sh
# on the pane's host as:
#   Q=<query> awk -F '\t' -v off=<offset> -v rows=<height> -v more=<file> -v count=<file> -f filter.awk items
#
# Input, one item per line, newest first:
#   label <TAB> url-or-empty <TAB> line-from-end <TAB> match
# Output, at most `rows` rows (default 9) for fzf: the matches after the
# first `off`, the top 9 numbered 1 to 9 and the rest unnumbered (field 1 is
# the item's index, which picks the job entry; field 2 is what's shown):
#   index <TAB> " N  label" <TAB> line-from-end <TAB> match
# Writes the header to `more` ("A-B of T", or "(no match)", then
# ENVIRON["HINT"]) and the number of matches to `count`.

# hit: whether q's characters appear in s in order (fuzzy, case-insensitive).
function hit(s, q,   i, k, p) {
  s = tolower(s); q = tolower(q); p = 0
  for (i = 1; i <= length(q); i++) {
    k = index(substr(s, p + 1), substr(q, i, 1)); if (!k) return 0; p += k
  }
  return 1
}
BEGIN { off += 0; if (off < 0) off = 0; rows += 0; if (rows < 1) rows = 9 }
hit($1, ENVIRON["Q"]) {
  n++
  if (n <= off || n > off + rows) next
  # Web links become OSC 8 hyperlinks, so they can be clicked in the pane too.
  if ($2 != "") d = sprintf("\033]8;;%s\033\\%s\033]8;;\033\\", $2, $1); else d = $1
  if (n - off <= 9) num = sprintf("\033[1;33m%d\033[0m", n - off); else num = " "
  printf "%d\t %s  %s\t%s\t%s\n", NR, num, d, $3, $4
}
END {
  if (n == 0) h = "(no match)"
  else h = sprintf("%d-%d of %d", (off < n ? off + 1 : n), (off + rows < n ? off + rows : n), n)
  printf "%s   %s\n", h, ENVIRON["HINT"] > more
  if (count != "") print n + 0 > count
}
