-- Tests for the pure parts of fzf_links/rexapi.lua (finding the Rex app's
-- tunnel socket). Run from anywhere: rex do path/to/rexapi_test.lua

local dir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or "./"
local T = dofile(dir .. "helper.lua")
local rexapi = require "fzf_links.rexapi"

-- The ssh child of the app's tunnel helper, as seen on a macOS client.
local SSH_LINE = "/usr/local/bin/ssh -N -T -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes"
  .. " -o StreamLocalBindMask=0177 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
  .. " -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10"
  .. " -L /Users/me/Library/Application Support/rex/ssh/p87771/ssh/27bdae05ea63579e.sock:/run/user/1000/rex/server.sock"
  .. " -- ssh://devbox.example.net"
local SOCK = "/Users/me/Library/Application Support/rex/ssh/p87771/ssh/27bdae05ea63579e.sock"

-- parse_forward
T.eq("forward with spaces", rexapi.parse_forward(SSH_LINE), SOCK)
T.eq("no -L", rexapi.parse_forward("/usr/bin/ssh -N -T -- ssh://devbox.example.net"), nil)
T.eq("helper line", rexapi.parse_forward("/x/rex __internal ssh-tunnel ssh://devbox.example.net"), nil)
T.eq("-L without a socket path", rexapi.parse_forward("ssh -L 8080:localhost:80 devbox"), nil)
T.eq("nil line", rexapi.parse_forward(nil), nil)

-- unix_url
T.eq(
  "url escapes spaces",
  rexapi.unix_url(SOCK),
  "unix:///Users/me/Library/Application%20Support/rex/ssh/p87771/ssh/27bdae05ea63579e.sock"
)
T.eq("url escapes percent", rexapi.unix_url("/tmp/a%b.sock"), "unix:///tmp/a%25b.sock")

-- ssh_endpoint, with the shape of `rex hosts list --json`
local hosts = {
  home = { label = "", endpoint = "unix:///tmp/server.sock", this_machine = true },
  hosts = {
    { host = { label = "devbox.example.net", endpoints = { "ssh://devbox.example.net" } }, from = "home" },
    { host = { label = "lab", endpoints = { "tcp://lab:7000", "ssh://me@lab" } }, from = "home" },
    { host = { label = "plain", endpoints = { "tcp://plain:7000" } }, from = "home" },
  },
}
T.eq("ssh endpoint", rexapi.ssh_endpoint(hosts, "devbox.example.net"), "ssh://devbox.example.net")
T.eq("ssh among others", rexapi.ssh_endpoint(hosts, "lab"), "ssh://me@lab")
T.eq("case-insensitive label", rexapi.ssh_endpoint(hosts, "LAB"), "ssh://me@lab")
T.eq("non-ssh endpoint", rexapi.ssh_endpoint(hosts, "plain"), nil)
T.eq("unknown label", rexapi.ssh_endpoint(hosts, "other"), nil)
T.eq("bad input", rexapi.ssh_endpoint(nil, "lab"), nil)

-- has_session, with the shape of `rex ls --json`
local ls = {
  sessions = {
    { session_id = "session:111", label = "main" },
    { session_id = "session:222", label = "work" },
  },
}
T.eq("matching session", rexapi.has_session(ls, "session:222"), true)
T.eq("other session", rexapi.has_session(ls, "session:999"), false)
T.eq("empty session id", rexapi.has_session(ls, ""), false)
T.eq("nil ls", rexapi.has_session(nil, "session:111"), false)

-- app_socket: both `rex hosts` ssh entries and ssh hosts configured only in
-- the Rex app UI (or shadowed by a stale non-ssh `rex hosts` entry).
local orig_rex, orig_run, orig_cli = _G.rex, rexapi.run, rexapi.rex_cli
local payloads = {}
_G.rex = {
  json = {
    decode = function(s)
      return assert(payloads[s], "unexpected json payload: " .. tostring(s))
    end,
  },
}
rexapi.rex_cli = function()
  return "/bin/rex"
end

local SSH_OTHER = "/usr/bin/ssh -N -L /tmp/other.sock:/run/rex/server.sock -- ssh://other.example.net"
local SOCK_URL = "unix:///Users/me/Library/Application%20Support/rex/ssh/p87771/ssh/27bdae05ea63579e.sock"

local function with_mock(spec, fn)
  local ls_calls = 0
  payloads = spec.payloads or {}
  rexapi.run = function(argv)
    if argv[1] == "/bin/rex" and argv[2] == "hosts" then
      return true, "HOSTS"
    end
    if argv[1] == "/bin/sh" then
      local ep = argv[5]
      return true, (spec.tunnels and spec.tunnels[ep]) or ""
    end
    if argv[1] == "/bin/test" and argv[2] == "-S" then
      return spec.sockets and spec.sockets[argv[3]] or false, ""
    end
    if argv[1] == "/bin/rex" and argv[2] == "-S" and argv[4] == "ls" then
      ls_calls = ls_calls + 1
      local tag = spec.ls and spec.ls[argv[3]]
      if tag then
        return true, tag
      end
      return false, "unreachable"
    end
    return false, "unexpected command: " .. table.concat(argv, " ")
  end
  fn(function()
    return ls_calls
  end)
end

-- 1. Fast path: `rex hosts` has an ssh:// endpoint with a live tunnel.
with_mock({
  payloads = { HOSTS = hosts },
  tunnels = { ["ssh://devbox.example.net"] = SSH_LINE },
  sockets = { [SOCK] = true },
}, function(ls_calls)
  local url, why = rexapi.app_socket("devbox.example.net", "session:222")
  T.eq("hosts ssh fast path", url, SOCK_URL)
  T.eq("hosts ssh fast path why", why, nil)
  T.eq("hosts ssh fast path skips ls", ls_calls(), 0)
end)

-- 2. App-UI ssh server not in `rex hosts` (or shadowed by a stale https entry
-- in `rex hosts`): finds the active tunnel that owns session_id.
local stale_hosts = {
  hosts = {
    { host = { label = "rpi5", endpoints = { "https://rpi5.example.ts.net/" } }, from = "home" },
  },
}
with_mock({
  payloads = {
    HOSTS = stale_hosts,
    LS_OTHER = { sessions = { { session_id = "session:other" } } },
    LS_RPI = ls,
  },
  tunnels = { [""] = SSH_OTHER .. "\n" .. SSH_LINE },
  sockets = { ["/tmp/other.sock"] = true, [SOCK] = true },
  ls = { ["unix:///tmp/other.sock"] = "LS_OTHER", [SOCK_URL] = "LS_RPI" },
}, function(ls_calls)
  local url, why = rexapi.app_socket("RPI5", "session:222")
  T.eq("app-ui ssh tunnel by session", url, SOCK_URL)
  T.eq("app-ui ssh tunnel why", why, nil)
  T.eq("app-ui checked both tunnels", ls_calls(), 2)
end)

-- 3. Non-ssh host whose session is not on any ssh tunnel: nil, nil (direct).
with_mock({
  payloads = {
    HOSTS = hosts,
    LS_OTHER = { sessions = { { session_id = "session:other" } } },
  },
  tunnels = { [""] = SSH_OTHER },
  sockets = { ["/tmp/other.sock"] = true },
  ls = { ["unix:///tmp/other.sock"] = "LS_OTHER" },
}, function()
  local url, why = rexapi.app_socket("plain", "session:direct")
  T.eq("non-ssh falls back to direct", url, nil)
  T.eq("non-ssh has no error", why, nil)
end)

-- 4. SSH host in `rex hosts` with no live tunnel: nil and reason.
with_mock({
  payloads = { HOSTS = hosts },
  tunnels = {},
  sockets = {},
}, function()
  local url, why = rexapi.app_socket("devbox.example.net", "session:222")
  T.eq("disconnected ssh url", url, nil)
  T.eq("disconnected ssh reason", why, "the Rex app has no connection to devbox.example.net")
end)

_G.rex, rexapi.run, rexapi.rex_cli = orig_rex, orig_run, orig_cli

return T.finish("rexapi")
