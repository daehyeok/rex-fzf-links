-- bin/dispatch.lua: open or copy a remote picker's choice on the client.
--
-- Started detached by the pick_link action for a pane on another host, right
-- after it opens the picker there. It connects to the server that owns the
-- picker pane and waits for one of two events from the picker's block:
--
--   rex -S <endpoint> do -s <session> bin/dispatch.lua \
--     job=<job dir> block=<picker block> token=<token> --for 30m
--
--   terminal.title_changed "rfl:<token>:<action>:<n>"  -> run item n, stop
--   terminal.child_exited (picker ended, no message)   -> stop (cancel)
--
-- <endpoint> is the Rex app's own tunnel socket for ssh hosts (see
-- lua/fzf_links/rexapi.lua, app_socket), so no new ssh connection is made.
-- `rex` here is that server, while rex.exec still runs on the client.
-- Everything it may run was built on the client before the picker opened
-- (job.json, see lua/fzf_links/run.lua); the title only selects an entry.
-- --for stops a forgotten dispatcher.

local src = debug.getinfo(1, "S").source
local dir = src:match("^@?(.*[/\\])") or "./"
package.path = dir .. "../lua/?.lua;" .. dir .. "../lua/?/init.lua;" .. package.path

local codes = require "fzf_links.codes"
local run = require "fzf_links.run"

local args = rex.args or {}

-- Read the job, then delete it at once, so every exit path (including the
-- --for deadline) leaves nothing behind.
local job
if type(args.job) == "string" and args.job ~= "" then
  local f = io.open(args.job .. "/job.json", "r")
  if f then
    local ok, decoded = pcall(rex.json.decode, f:read("*a"))
    f:close()
    if ok and type(decoded) == "table" then
      job = decoded
    end
  end
  run.remove_job({ dir = args.job })
end
if not (job and args.block and codes.valid_token(args.token)) then
  run.log("dispatcher: incomplete job")
  return
end

-- The picker may already be gone (closed before we connected).
local ok, res = pcall(rex.session.describe_block, { session_id = rex.session_id, block_id = args.block })
if not ok or res == nil then
  run.log("dispatcher: picker block %s is gone", tostring(args.block))
  return
end

local done = false

rex.on("terminal.title_changed", function(ctx, ev)
  if done or ctx.block_id ~= args.block then
    return
  end
  local action, n = codes.decode(ev and ev.title, args.token)
  if not action then
    return
  end
  done = true
  run.run(job, action, n)
  rex.stop(0)
end)

rex.on("terminal.child_exited", function(ctx)
  if done or ctx.block_id ~= args.block then
    return
  end
  done = true
  rex.stop(0)
end)
