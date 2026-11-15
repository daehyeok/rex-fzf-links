-- fzf_links/codes.lua: the message a remote picker sends back to the client.
--
-- A picker over a pane on another host can't open or copy anything on the
-- client itself. Instead it sets its own terminal title (OSC 2) to one line,
-- which the client's dispatcher sees as a terminal.title_changed event:
--
--   rfl:<token>:open:<n>     open item n
--   rfl:<token>:copy:<n>     copy item n
--
-- <token> is 16 lowercase hex characters, new for every picker, known only to
-- the client and that picker; <n> counts from 1 and has no maximum. A cancel
-- sends nothing: the picker just exits. The client acts only on a title with
-- its own token, and only on the commands it built itself, so nothing the
-- remote side writes is ever executed.
--
-- Pure Lua 5.1; no rex.* calls, so it is tested without a session.

local M = {}

M.PREFIX = "rfl:"
M.TOKEN_LEN = 16

local ACTIONS = { open = true, copy = true }

local function valid_token(token)
  return type(token) == "string" and #token == M.TOKEN_LEN and not token:find("[^0-9a-f]")
end
M.valid_token = valid_token

-- Returns the title for action ("open" | "copy") and item n, or nil when an
-- argument is invalid.
function M.encode(token, action, n)
  if not valid_token(token) or not ACTIONS[action] then
    return nil
  end
  if type(n) ~= "number" or n < 1 or n % 1 ~= 0 then
    return nil
  end
  return string.format("%s%s:%s:%d", M.PREFIX, token, action, n)
end

-- Returns action, n for a title carrying token, or nil for anything else
-- (another token, extra text, a malformed title).
function M.decode(title, token)
  if type(title) ~= "string" or not valid_token(token) then
    return nil
  end
  local head = M.PREFIX .. token .. ":"
  if title:sub(1, #head) ~= head then
    return nil
  end
  local action, n = title:sub(#head + 1):match("^(%a+):(%d+)$")
  n = tonumber(n)
  if not action or not ACTIONS[action] or not n or n < 1 then
    return nil
  end
  return action, n
end

return M
