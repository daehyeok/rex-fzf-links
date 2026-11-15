-- Tests for fzf_links/scrollback.lua against a fake terminal.
-- Run from anywhere: rex do path/to/scrollback_test.lua (or lua ...)

local dir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or "./"
local T = dofile(dir .. "helper.lua")
local scrollback = require "fzf_links.scrollback"

local SPLIT = "\239\191\189"

-- A fake terminal holding `text`, following the API docs: format returns the
-- first max_bytes (with id and total while more remains); blob_read returns up
-- to max_bytes from an offset, never ending inside a character, and one
-- U+FFFD per byte when it starts inside one.
-- opts.whole: format always returns the whole text, with no id or total.
local function terminal(text, opts)
  opts = opts or {}
  local log = {}
  local function cont(i)
    local b = text:byte(i)
    return b and b >= 128 and b < 192
  end
  local function slice(from, n) -- bytes from+1 .. from+n, ending on a character
    local last = math.min(from + n, #text)
    while last > from and cont(last + 1) do
      last = last - 1
    end
    local s = text:sub(from + 1, last)
    local lead = s:match("^[\128-\191]+") or ""
    return SPLIT:rep(#lead) .. s:sub(#lead + 1), last
  end
  local call = function(method, args)
    log[#log + 1] = { method = method, args = args }
    if method == "format" then
      if opts.whole then
        return { content = text }
      end
      local s, last = slice(0, args.max_bytes)
      if last >= #text then
        return { content = s, eof = true }
      end
      return { content = s, id = 9, total = #text, eof = false }
    elseif method == "blob_read" then
      assert(args.id == 9, "blob_read with the format reply's id")
      local s, last = slice(args.offset, args.max_bytes)
      return { id = 9, data = s, total = #text, eof = last >= #text }
    end
    error("unexpected method " .. method)
  end
  return call, log
end

local function numbered(n, fmt)
  local t = {}
  for i = 1, n do
    t[i] = string.format(fmt or "line %04d https://e.example/%d", i, i)
  end
  return t
end

-- Short text: one call, returned as is.
local call, log = terminal("a\nb https://x\n")
T.eq("short text", scrollback.tail(call, 1024), "a\nb https://x\n")
T.eq("short text: one call", #log, 1)

-- Long pane: the newest line is kept, old lines go, the start is a line.
local lines = numbered(2000)
local long = table.concat(lines, "\n")
local got = scrollback.tail(terminal(long), 1024)
T.check("long: newest line kept", got:sub(-#lines[2000]) == lines[2000], got:sub(-40))
T.check("long: oldest line dropped", not got:find("line 0001 ", 1, true))
T.check("long: starts at a line", got:match("^line %d%d%d%d ") ~= nil, got:sub(1, 20))
T.check("long: within the limit", #got <= 1024, #got)

-- Smaller limit: a link printed more than `limit` bytes before the end is gone.
local text = "old https://old.example\n" .. ("x"):rep(2000) .. "\nnew https://new.example"
got = scrollback.tail(terminal(text), 1024)
T.check("limit: old link gone", not got:find("old.example", 1, true), got:sub(1, 40))
T.check("limit: new link kept", got:find("new.example", 1, true) ~= nil)

-- A line starting exactly `limit` bytes before the end is kept whole.
local tail_line = "edge https://edge.example"
text = ("y"):rep(500) .. "\n" .. tail_line .. "\n" .. ("z"):rep(70)
local limit = #tail_line + 1 + 70
T.eq("line at the limit kept", scrollback.tail(terminal(text), limit), tail_line .. "\n" .. ("z"):rep(70))

-- Reading in several parts.
local old_part = scrollback.PART
scrollback.PART = 100
local parts_log
call, parts_log = terminal(long)
got = scrollback.tail(call, 5000)
scrollback.PART = old_part
T.check("parts: ends with the last line", got:sub(-#lines[2000]) == lines[2000])
T.check("parts: starts at a line", got:match("^line %d%d%d%d ") ~= nil, got:sub(1, 20))
T.check("parts: several reads", #parts_log > 3, #parts_log)

-- The cut inside a multi-byte character: no U+FFFD, line boundary kept.
text = ("x"):rep(50) .. "\n" .. ("é"):rep(100) .. "\nlast https://u.example"
for _, lim in ipairs({ 60, 61, 62, 63 }) do
  got = scrollback.tail(terminal(text), lim)
  T.check("multi-byte cut " .. lim .. ": no U+FFFD", not got:find(SPLIT, 1, true), got)
  T.eq("multi-byte cut " .. lim .. ": from the last line", got, "last https://u.example")
end
text = "a\n" .. ("é"):rep(400) .. "\n" .. ("ü"):rep(30) .. "\nend"
for lim = 70, 73 do
  got = scrollback.tail(terminal(text), lim)
  T.eq("multi-byte line kept at " .. lim, got, ("ü"):rep(30) .. "\nend")
end

-- One line longer than the limit: its end, from a character start.
text = ("é"):rep(300) .. "https://end.example"
for _, lim in ipairs({ 40, 41 }) do
  got = scrollback.tail(terminal(text), lim)
  T.check("one long line " .. lim .. ": keeps its end", got:sub(-19) == "https://end.example", got)
  T.check(
    "one long line " .. lim .. ": starts on a character",
    not got:match("^[\128-\191]") and not got:find(SPLIT, 1, true),
    got:sub(1, 4)
  )
  T.check("one long line " .. lim .. ": within the limit", #got <= lim, #got)
end

-- A server that sends the whole text at once is still cut to the limit.
got = scrollback.tail(terminal(long, { whole = true }), 1024)
T.check("whole reply: within the limit", #got <= 1024, #got)
T.check("whole reply: starts at a line", got:match("^line %d%d%d%d ") ~= nil, got:sub(1, 20))
T.check("whole reply: newest line kept", got:sub(-#lines[2000]) == lines[2000])
T.eq("whole reply, short", scrollback.tail(terminal("x\ny", { whole = true }), 1024), "x\ny")

-- The head asked for is small; the total is under the limit: everything.
call, log = terminal(long)
got = scrollback.tail(call, #long + 10)
T.eq("total under the limit: whole text", got, long)
T.check("first reply is small", log[1].args.max_bytes <= scrollback.HEAD, log[1].args.max_bytes)

-- Errors pass through, from format and from blob_read.
local r, err = scrollback.tail(function()
  return nil, "boom"
end, 100)
T.check("format error", r == nil and err == "boom", tostring(err))
local real = terminal(long)
r, err = scrollback.tail(function(m, a)
  if m == "blob_read" then
    return nil, "gone"
  end
  return real(m, a)
end, 1024)
T.check("blob_read error", r == nil and err == "gone", tostring(err))

return T.finish("scrollback")
