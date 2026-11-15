-- fzf_links/rexapi.lua: the few Rex calls the plugin needs, with the
-- remote-server fallback.
--
-- Runs in the Rex config (init.lua) on the client. A pane on a remote host
-- belongs to that host's Rex server: calls about it go first to the local
-- server, and when that finds nothing, to rex.server(ctx.server).

local M = {}

M.TERMINAL = "com.superlogical.terminal"

-- Where the Rex app keeps its CLI on macOS.
local MAC_REX_CLI = (os.getenv("HOME") or "")
  .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end
M.file_exists = file_exists

-- Returns the path of the client's rex CLI: $REX_BIN_DIR/rex, then the macOS
-- app bundle, then plain "rex" from PATH.
function M.rex_cli()
  local bin = os.getenv("REX_BIN_DIR")
  if bin and bin ~= "" and file_exists(bin .. "/rex") then
    return bin .. "/rex"
  end
  if file_exists(MAC_REX_CLI) then
    return MAC_REX_CLI
  end
  return "rex"
end

-- Attaches the calling stream to a session. Calls made outside a key press
-- (e.g. an action run with `rex do`) start without one.
local function attach(api, session_id)
  if session_id and api.session and type(api.session.attach) == "function" then
    pcall(api.session.attach, { session_id = session_id })
  end
end

-- Calls a terminal method on ctx's block, on whichever server owns it.
-- Returns the result, or nil and an error.
function M.terminal_call(ctx, method, extra)
  local args = { block_id = ctx.block_id, session_id = ctx.session_id }
  for k, v in pairs(extra or {}) do
    args[k] = v
  end
  local r, err = rex.block.call(M.TERMINAL, method, args)
  if r ~= nil then
    return r, err
  end
  if tostring(err):find("not attached", 1, true) then
    attach(rex, ctx.session_id)
    r, err = rex.block.call(M.TERMINAL, method, args)
    if r ~= nil then
      return r, err
    end
  end
  if not ctx.server then
    return r, err
  end
  local srv = rex.server(ctx.server)
  r, err = srv.block.call(M.TERMINAL, method, args)
  if r ~= nil then
    return r, err
  end
  -- A server we haven't attached to yet doesn't know the session.
  attach(srv, ctx.session_id)
  return srv.block.call(M.TERMINAL, method, args)
end

-- Creates a floating layer on the server that owns ctx's pane.
-- Returns the new_layer result ({ block_ids, layer_id, ... }) and the server
-- label it was created on (nil = local), or nil and an error.
function M.new_layer(ctx, req)
  local res, err = rex.session.new_layer(req)
  if res ~= nil and err == nil then
    return res, nil
  end
  if ctx.server then
    res, err = rex.server(ctx.server).session.new_layer(req)
    if res ~= nil and err == nil then
      return res, ctx.server
    end
  end
  return nil, nil, tostring(err)
end

-- Calls a session method on the server that owns ctx's pane (local first,
-- then rex.server(ctx.server)). Returns true when one of them accepted it.
local function session_call(ctx, method, args)
  local apis = { rex }
  if ctx.server then
    apis[2] = rex.server(ctx.server)
  end
  for _, api in ipairs(apis) do
    attach(api, args.session_id)
    local fn = api.session and api.session[method]
    local ok, res, err = pcall(function()
      if fn then
        return fn(args)
      end
      return api.call("session." .. method, args)
    end)
    if ok and res ~= nil and err == nil then
      return true
    end
  end
  return false
end

-- Closes a floating layer in ctx's session.
function M.close_layer(ctx, layer_id)
  if not layer_id then
    return false
  end
  return session_call(ctx, "close_layer", { session_id = ctx.session_id, layer_id = layer_id })
end

-- Focuses a block in ctx's session (e.g. the pane a floating layer covered).
function M.focus_block(ctx, block_id)
  return session_call(ctx, "focus_block", { session_id = ctx.session_id, block_id = block_id })
end

-- Runs argv on the client and returns true, or false and a one-line error
-- (stderr without its timestamp prefix, or the exit status).
-- opts are passed to rex.exec (e.g. { stdin = text, timeout = 10 }).
function M.run(argv, opts)
  local r, err = rex.exec(argv, opts or { timeout = 30 })
  if not r then
    return false, tostring(err)
  end
  if not r.ok then
    local msg = (r.stderr or ""):gsub("^%d+%-%d+%-%d+ %d+:%d+:%d+ [%w%._%-]+: ", ""):gsub("%s+$", "")
    return false, msg ~= "" and msg or (argv[1] .. " exited " .. tostring(r.code))
  end
  return true, r.stdout
end

-- Finding the Rex app's own tunnel to an ssh host.
--
-- For every ssh host it is connected to, the macOS Rex app runs a helper,
-- `rex __internal ssh-tunnel ssh://HOST`, whose ssh child forwards a local
-- unix socket to that host's Rex server:
--   ssh -N ... -L <local socket>:<remote server.sock> -- ssh://HOST
-- A client process can talk to the host's server through that socket with no
-- new ssh connection. This is an internal detail of the app, so it is kept to
-- the functions below; see README, "Remote hosts" and "Limits".

local function first_ssh(h)
  for _, ep in ipairs(h.endpoints or {}) do
    if type(ep) == "string" and ep:sub(1, 6) == "ssh://" then
      return ep
    end
  end
  return nil
end

-- Returns the label's ssh:// endpoint from decoded `rex hosts list --json`
-- output, or nil when the label has none (unknown label, other kinds).
-- Matches exact label first, then case-insensitively (the way `rex -S` does).
function M.ssh_endpoint(hosts, label)
  if type(label) ~= "string" or label == "" then
    return nil
  end
  local list = type(hosts) == "table" and hosts.hosts or {}
  for _, entry in ipairs(list) do
    local h = type(entry) == "table" and entry.host or nil
    if type(h) == "table" and h.label == label then
      return first_ssh(h)
    end
  end
  local want = label:lower()
  for _, entry in ipairs(list) do
    local h = type(entry) == "table" and entry.host or nil
    if type(h) == "table" and type(h.label) == "string" and h.label:lower() == want then
      return first_ssh(h)
    end
  end
  return nil
end

-- Returns true when decoded `rex ls --json` output lists `session_id`.
function M.has_session(ls, session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return false
  end
  for _, s in ipairs(type(ls) == "table" and ls.sessions or {}) do
    if type(s) == "table" and s.session_id == session_id then
      return true
    end
  end
  return false
end

-- Returns the local socket path of an ssh command line's `-L <path>:/...`
-- forward, or nil when it has none. The path may contain spaces.
function M.parse_forward(cmdline)
  if type(cmdline) ~= "string" then
    return nil
  end
  return cmdline:match(" %-L (/.-):/")
end

-- Returns a unix:// URL for a socket path (spaces and % escaped).
function M.unix_url(path)
  return "unix://" .. path:gsub("%%", "%%25"):gsub(" ", "%%20")
end

-- Prints the command lines of the ssh children of the app's tunnel helpers
-- (only those for endpoint $1 when $1 is non-empty).
local TUNNEL_CHILDREN = [[
for hp in $(pgrep -f '__internal ssh-tunnel '); do
  if [ -n "$1" ]; then
    case "$(ps -ww -o command= -p "$hp")" in *" ssh-tunnel $1") ;; *) continue ;; esac
  fi
  for cp in $(pgrep -P "$hp"); do ps -ww -o command= -p "$cp"; done
done
exit 0
]]

local function tunnel_sockets(endpoint)
  local ok, lines = M.run({ "/bin/sh", "-c", TUNNEL_CHILDREN, "sh", endpoint or "" }, { timeout = 5 })
  if not ok then
    return nil
  end
  local urls, seen = {}, {}
  for line in lines:gmatch("[^\n]+") do
    local path = M.parse_forward(line)
    if path and not seen[path] and M.run({ "/bin/test", "-S", path }, { timeout = 5 }) then
      seen[path] = true
      urls[#urls + 1] = M.unix_url(path)
    end
  end
  return urls
end

-- Returns the unix:// URL of the Rex app's tunnel socket to the server
-- labelled `label` (or owning `session_id`, for ssh servers added in the app
-- rather than `rex hosts`). Returns nil, nil when no ssh endpoint or tunnel
-- matches (use a direct connection), or nil and a reason when `rex hosts`
-- names an ssh host the app has no tunnel to.
function M.app_socket(label, session_id)
  local decode = rex and rex.json and rex.json.decode
  if not decode then
    return nil, nil
  end
  local cli = M.rex_cli()
  local endpoint
  local ok, out = M.run({ cli, "hosts", "list", "--json" }, { timeout = 5 })
  if ok then
    local dok, hosts = pcall(decode, out)
    endpoint = dok and M.ssh_endpoint(hosts, label) or nil
  end
  if endpoint then
    local urls = tunnel_sockets(endpoint)
    if urls and urls[1] then
      return urls[1]
    end
  end
  if type(session_id) == "string" and session_id ~= "" then
    for _, url in ipairs(tunnel_sockets("") or {}) do
      local lok, lout = M.run({ cli, "-S", url, "ls", "--json" }, { timeout = 3 })
      if lok then
        local dok, ls = pcall(decode, lout)
        if dok and M.has_session(ls, session_id) then
          return url
        end
      end
    end
  end
  if endpoint then
    return nil, "the Rex app has no connection to " .. tostring(label)
  end
  return nil, nil
end

-- Makes a private (0700) temporary directory on the client.
-- Returns its path, or nil and an error.
function M.private_tmpdir(prefix)
  local ok, out = M.run(
    { "/bin/sh", "-c", 'umask 077 && mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"', "sh", prefix },
    { timeout = 5 }
  )
  if not ok then
    return nil, out
  end
  return (out:gsub("%s+$", ""))
end

return M
