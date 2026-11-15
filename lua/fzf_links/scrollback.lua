-- fzf_links/scrollback.lua: the newest part of a pane's text.
--
-- Runs in the Rex config on the client, through the terminal's API:
--   format { max_bytes = n }  the first n bytes of the text, plus the text's
--                             `total` size and an `id` when more remains
--                             (`eof` when it doesn't)
--   blob_read { id, offset }  more of that same text, from a byte offset
-- So the reader asks for a small head (which gives the size), then reads
-- from `limit` bytes before the end.

local M = {}

-- The size of the first reply, which is mostly for learning the total.
M.HEAD = 4096
-- The most bytes one blob_read returns (the API's cap, 960 KiB).
M.PART = 983040

-- What the terminal sends for each byte of a character that a read starts in.
local SPLIT = "\239\191\189" -- U+FFFD

-- Drops whole bytes of a character cut at the front: UTF-8 continuation bytes.
local function from_char_start(s)
  return (s:gsub("^[\128-\191]+", ""))
end

-- text begins partway into the pane, one byte before the limit. Drops its
-- first line, which started before the limit (when that byte is a line break,
-- only the break goes). One line with no break keeps its last `limit` bytes.
local function drop_first_line(text, limit)
  local nl = text:find("\n", 1, true)
  if nl then
    return text:sub(nl + 1)
  end
  return from_char_start(text:sub(-limit))
end

-- Reads the text identified by id from offset to its end. The first part may
-- start inside a character: the terminal sends one U+FFFD per byte of it,
-- which stands for one byte of the text and is dropped.
local function read_from(call, id, offset)
  local parts, first = {}, true
  while true do
    local r, err = call("blob_read", { id = id, offset = offset, max_bytes = M.PART })
    if r == nil then
      return nil, err
    end
    local data = r.data or ""
    local used = #data
    if first then
      first = false
      local skipped = 0
      while data:sub(1, 3) == SPLIT do
        data, skipped = data:sub(4), skipped + 1
      end
      used = #data + skipped
    end
    parts[#parts + 1] = data
    offset = offset + used
    if r.eof or used == 0 then
      break
    end
  end
  return table.concat(parts)
end

-- Returns at most the last `limit` bytes of the pane's text (plain text,
-- wrapped lines joined, trailing spaces trimmed), starting at a line boundary,
-- or nil and an error.
-- call(method, args) -> result | nil, err  calls a terminal method on the pane.
function M.tail(call, limit)
  local r, err = call("format", {
    format = "text",
    trim = true,
    unwrap = true,
    max_bytes = math.min(M.HEAD, limit),
  })
  if r == nil then
    return nil, err
  end
  local head = r.content or ""

  if r.id == nil or r.eof then -- the whole text came in this reply
    if #head <= limit then
      return head
    end
    return drop_first_line(head:sub(-limit - 1), limit)
  end

  if r.total ~= nil and r.total > limit then
    local text
    text, err = read_from(call, r.id, r.total - limit - 1)
    if text == nil then
      return nil, err
    end
    return drop_first_line(text, limit)
  end

  local rest
  rest, err = read_from(call, r.id, #head)
  if rest == nil then
    return nil, err
  end
  local text = head .. rest
  if #text <= limit then
    return text
  end -- no total: cut here
  return drop_first_line(text:sub(-limit - 1), limit)
end

return M
