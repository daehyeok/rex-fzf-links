-- Tests for fzf_links/extract.lua. Run from anywhere: rex do path/to/extract_test.lua

local dir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or "./"
local T = dofile(dir .. "helper.lua")
local extract = require "fzf_links.extract"

local function labels(items)
  local out = {}
  for i, it in ipairs(items) do
    out[i] = it.label
  end
  return table.concat(out, " | ")
end

-- Checks the labels (and optionally the targets) extract yields, newest first.
local function check_extract(name, text, opts, want_labels, want_targets)
  local items = extract.extract(text, opts or {})
  local ok = labels(items) == table.concat(want_labels, " | ")
  for i, t in ipairs(want_targets or {}) do
    if not items[i] or items[i].target ~= t then
      ok = false
    end
  end
  local targets = {}
  for i, it in ipairs(items) do
    targets[i] = it.target
  end
  T.check(
    name,
    ok,
    string.format(
      "\n    want: %s\n    got:  %s  (targets: %s)",
      table.concat(want_labels, " | "),
      labels(items),
      table.concat(targets, " | ")
    )
  )
end

local short = {
  patterns = {
    { match = "^t/%d+$", url = "http://%0" },
    { match = "^wiki/[%w._%-]+$", url = "http://%0" },
  },
}
local MOUNT = "/srv/mnt/data"
local remote_pane = {
  resolve_file = function(p)
    if p:sub(1, #MOUNT + 1) == MOUNT .. "/" then
      return p
    end
  end,
}
local existing = { ["/home/user/notes.md"] = true }
local local_pane = {
  resolve_file = function(p)
    if existing[p] then
      return p
    end
  end,
}

-- URLs
check_extract("https url", "see https://example.com/x for details", nil, { "https://example.com/x" })
check_extract(
  "trailing period",
  "See https://example.com/docs.",
  nil,
  { "https://example.com/docs" },
  { "https://example.com/docs" }
)
check_extract("url inside a token", "url=https://example.com/a)", nil, { "https://example.com/a" })
check_extract("bare scheme is not a url", "https://", nil, {})

-- Custom patterns
check_extract(
  "issue key with capture",
  "(ENG-12)",
  { patterns = { { match = "^(%u+%-%d+)$", url = "https://issues.example.com/%1" } } },
  { "ENG-12" },
  { "https://issues.example.com/ENG-12" }
)
check_extract("short link in a sentence", "Created t/823411.", short, { "t/823411" }, { "http://t/823411" })
check_extract(
  "bracketed and quoted",
  'see (t/31337) and "wiki/rex-docs"',
  short,
  { "wiki/rex-docs", "t/31337" },
  { "http://wiki/rex-docs", "http://t/31337" }
)
check_extract("partial token does not match", "src/t/12.c abc/t/1", short, {})
check_extract(
  "unanchored pattern still needs the whole token",
  "xx-t/1",
  { patterns = { { match = "t/%d+", url = "http://%0" } } },
  {}
)
check_extract(
  "literal percent in template",
  "t/5",
  { patterns = { { match = "^t/(%d+)$", url = "http://q?id=%1%%" } } },
  { "t/5" },
  { "http://q?id=5%" }
)
check_extract("no patterns, no short links", "t/123", nil, {})

-- Files
check_extract(
  "remote mount file:// url",
  "artifact: file://" .. MOUNT .. "/doc/plan.md",
  remote_pane,
  { MOUNT .. "/doc/plan.md" },
  { MOUNT .. "/doc/plan.md" }
)
check_extract("line:col suffix dropped", MOUNT .. "/doc/walk.md:12:3", remote_pane, { MOUNT .. "/doc/walk.md" })
check_extract("remote path outside mount", "/var/log/syslog", remote_pane, {})
check_extract("local existing file", "open /home/user/notes.md now", local_pane, { "/home/user/notes.md" })
check_extract("local missing file", "/home/user/missing.md", local_pane, {})
check_extract("files ignored without resolve_file", "/home/user/notes.md", nil, {})
check_extract("double slash is not a path", "//comment", local_pane, {})

-- Newest first, no duplicates
check_extract(
  "same link twice",
  "https://a.example\nhttps://b.example\nhttps://a.example",
  nil,
  { "https://a.example", "https://b.example" }
)
check_extract("right of a line is newer", "t/1 t/2\nt/3", short, { "t/3", "t/2", "t/1" })
check_extract("crlf lines", "t/1\r\nt/2\r\n", short, { "t/2", "t/1" })
check_extract("empty text", "", nil, {})

-- Item limit keeps the newest
local many = {}
for i = 1, 80 do
  many[i] = "https://x.example/" .. i
end
local capped = extract.extract(table.concat(many, "\n"), { max_items = 60 })
T.eq("cap at 60", #capped, 60)
T.eq("cap keeps newest first", capped[1].label, "https://x.example/80")
T.eq("cap drops oldest", capped[60].label, "https://x.example/21")

-- Line numbers (the picker previews around them)
local items = extract.extract("a\nb\nsee t/7 here\nd\ne", short)
T.eq("line of a link", items[1].line, 3)
T.eq("line from end", items[1].line_from_end, 3)
items = extract.extract("t/1\nx\nt/1\nt/2", short)
T.eq("duplicate keeps the bottom line", items[2].line, 3)

return T.finish("extract")
