-- fzf_links/extract.lua: find openable links in a pane's text.
--
--   extract(text, opts) -> items, newest first, one per target
--
--   item = {
--     label = text as shown in the pane, e.g. "ENG-12" or "/tmp/a.txt",
--     kind  = "url" | "file",
--     target = what opens: a URL, or the client-side path of a file,
--     line  = 1-based line of the newest occurrence in text,
--     line_from_end = the same line counted from the last line (1 = last),
--   }
--
--   opts.patterns     = { { match = <Lua pattern>, url = <template> }, ... }
--                       match is tried against a whole token (with its
--                       surrounding punctuation removed); in url, %0 is the
--                       token and %1..%9 its captures, %% a literal %.
--   opts.resolve_file = function(path) -> client_path | nil; decides whether
--                       an absolute path or file:// URL counts. Without it, no
--                       file links are found.
--   opts.max_items    = keep at most this many items (the newest).
--
-- Pure Lua 5.1; no rex.* calls.

local M = {}

local LEADING = "^[%(%[{<'\"`]+"
local TRAILING = "[%.,;:!%?%)%]}>'\"`]+$"

local function trim_punct(tok)
  return (tok:gsub(LEADING, ""):gsub(TRAILING, ""))
end

-- Fills a url template: %0 = whole match, %1..%9 = captures, %% = %.
local function fill(template, whole, caps)
  return (
    template:gsub("%%([%d%%])", function(c)
      if c == "%" then
        return "%"
      end
      if c == "0" then
        return whole
      end
      return caps[tonumber(c)] or ""
    end)
  )
end

-- Returns an item for the first user pattern matching the whole token, or nil.
local function match_pattern(tok, patterns)
  for _, p in ipairs(patterns) do
    local res = { tok:find(p.match) }
    if res[1] == 1 and res[2] == #tok then
      local caps = {}
      for i = 3, #res do
        caps[i - 2] = tostring(res[i])
      end
      return { label = tok, kind = "url", target = fill(p.url, tok, caps) }
    end
  end
  return nil
end

-- Returns an item for one whitespace-separated token, or nil.
local function classify(tok, opts)
  -- A URL anywhere in the token (e.g. url=https://...); brackets and quotes
  -- around it are trimmed.
  local s = tok:find("https?://")
  if s then
    local url = trim_punct(tok:sub(s))
    if #url > #"https://" then
      return { label = url, kind = "url", target = url }
    end
    return nil
  end

  tok = trim_punct(tok)
  if tok == "" then
    return nil
  end

  -- file:///abs/path, file://host/abs/path, or a plain absolute path
  local path = tok:match("^file://[^/]*(/.*)$")
  if not path and tok:sub(1, 1) == "/" and tok:sub(2, 2) ~= "/" and #tok > 1 then
    path = tok
  end
  if path then
    path = path:gsub(":%d+:%d+$", ""):gsub(":%d+$", "") -- drop :line[:col]
    local resolved = opts.resolve_file and opts.resolve_file(path)
    if resolved then
      return { label = path, kind = "file", target = resolved }
    end
    return nil
  end

  return match_pattern(tok, opts.patterns or {})
end

function M.extract(text, opts)
  opts = opts or {}
  local lines = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do
    lines[#lines + 1] = line
  end
  local total = #lines

  local items, seen = {}, {}
  local max = opts.max_items or math.huge
  for i = total, 1, -1 do -- bottom (newest) to top
    local found = {}
    for tok in lines[i]:gmatch("%S+") do
      local item = classify(tok, opts)
      if item then
        item.line = i
        item.line_from_end = total - i + 1
        found[#found + 1] = item
      end
    end
    for j = #found, 1, -1 do -- the right of a line is newer than the left
      local item = found[j]
      if not seen[item.target] then
        seen[item.target] = true
        items[#items + 1] = item
        if #items >= max then
          return items
        end
      end
    end
  end
  return items
end

return M
