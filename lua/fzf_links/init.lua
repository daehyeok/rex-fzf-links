-- rex-fzf-links: open or copy the links printed in the focused Rex pane.
--
-- fzf_links/init.lua runs in the Rex config (init.lua) on the client.
-- setup(opts) registers two actions and binds no keys; bind them yourself:
--
--   local fzf_links = require("plugins.rex-fzf-links")
--   fzf_links.setup({})
--   rex.bind("alt+u", "pick_link")            -- floating picker
--   rex.bind("alt+shift+u", "open_last_link") -- newest link, no picker
--
-- How a pick reaches the client:
--   1. the action reads the pane's text, finds its links and builds, on the
--      client, the open and copy command for every link;
--   2. it writes those commands to a private job file (job.json);
--   3. local pane: the picker runs on the client and, on a pick, runs
--      bin/act.lua on the job itself. Nothing else is started.
--      remote pane: the picker runs on the pane's host and reports a pick by
--      setting its title (codes.lua). A detached bin/dispatch.lua, connected
--      to that host's Rex server (through the Rex app's own tunnel for ssh
--      hosts, see rexapi.app_socket), runs the chosen command on the client.
-- See README.md for the options and the limits.

local codes = require "fzf_links.codes"
local config = require "fzf_links.config"
local extract = require "fzf_links.extract"
local json = require "fzf_links.json"
local message = require "fzf_links.message"
local picker = require "fzf_links.picker"
local rexapi = require "fzf_links.rexapi"
local run = require "fzf_links.run"
local scrollback = require "fzf_links.scrollback"

local M = {}

-- The plugin's root directory (this file is lua/fzf_links/init.lua).
local ROOT = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../../"

-- Rex kills the processes an action starts once the action returns, so the
-- dispatcher double-forks into its own session to outlive it. Its output goes
-- to a log file in the client's temp dir.
local DETACH = [[
exit 0 if fork(); POSIX::setsid(); exit 0 if fork();
open(STDIN, "</dev/null"); open(STDOUT, ">>", shift @ARGV); open(STDERR, ">&STDOUT");
exec(@ARGV) or die "exec $ARGV[0]: $!\n";
]]

-- How long a remote picker's dispatcher waits for a pick.
local DISPATCH_FOR = "30m"

local NO_LINKS = "No links in this pane"

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, err
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- Loads the shell and awk scripts the panes run, once.
local share
local function load_share()
  if share then
    return share
  end
  local s, err = {}
  s.picker, err = read_file(ROOT .. "share/picker.sh")
  if not s.picker then
    return nil, err
  end
  s.filter, err = read_file(ROOT .. "share/filter.awk")
  if not s.filter then
    return nil, err
  end
  s.message, err = read_file(ROOT .. "share/message.sh")
  if not s.message then
    return nil, err
  end
  share = s
  return share
end

-- Shows msg in a message pane; falls back to the Rex log if even that fails.
local function say(ctx, msg)
  local s, err = load_share()
  local ok = false
  if s then
    ok, err = message.show(ctx, msg, s.message)
  end
  if not ok then
    io.stderr:write("rex-fzf-links: " .. msg .. " (" .. tostring(err) .. ")\n")
  end
end

-- Returns the focused pane's links, newest first, or nil and an error.
local function find_links(ctx, cfg)
  local text, err = scrollback.tail(function(method, args)
    return rexapi.terminal_call(ctx, method, args)
  end, cfg.max_scrollback)
  if not text then
    return nil, err
  end
  return extract.extract(text, {
    patterns = cfg.patterns,
    resolve_file = config.file_resolver(cfg, ctx, rexapi.file_exists),
    max_items = cfg.max_items,
  })
end
M._find_links = find_links

-- Returns the open argv (target appended) and the copy argv and text for item.
local function commands_for(cfg, item, ctx)
  local defaults = config.client_defaults()
  local open = config.command_for(cfg, "open_cmd", item, ctx, defaults.open)
  if open then
    open[#open + 1] = item.target
  end
  local copy = config.command_for(cfg, "copy_cmd", item, ctx, defaults.copy)
  -- Copy what the user sees: the URL, or the path as printed in the pane.
  return open, copy, item.kind == "url" and item.target or item.label
end

-- open_last_link: open the newest link in the focused pane.
local function open_last_link(ctx, cfg)
  local items, err = find_links(ctx, cfg)
  if not items then
    return say(ctx, "Can't read this pane: " .. tostring(err))
  end
  if #items == 0 then
    return say(ctx, NO_LINKS)
  end
  local argv = commands_for(cfg, items[1], ctx)
  if not argv then
    return say(ctx, "No command to open " .. items[1].label)
  end
  local ok, oerr = rexapi.run(argv)
  if not ok then
    say(ctx, "Can't open " .. items[1].label .. ": " .. tostring(oerr))
  end
end

-- Returns a new one-time token (codes.lua) from /dev/urandom, or nil.
local function new_token()
  local f = io.open("/dev/urandom", "rb")
  if not f then
    return nil
  end
  local n = codes.TOKEN_LEN / 2
  local bytes = f:read(n)
  f:close()
  if not bytes or #bytes ~= n then
    return nil
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

-- Writes the job into a new private dir. Returns the dir, or nil and an error.
local function write_job(job)
  local dir, err = rexapi.private_tmpdir("rex-fzf-links")
  if not dir then
    return nil, err
  end
  local f, ferr = io.open(dir .. "/job.json", "w")
  if not f then
    os.remove(dir)
    return nil, ferr
  end
  f:write(json.encode(job))
  f:close()
  return dir
end

-- pick_link: show the picker; a pick runs on the client (see the top).
local function pick_link(ctx, cfg)
  local items, err = find_links(ctx, cfg)
  if not items then
    return say(ctx, "Can't read this pane: " .. tostring(err))
  end
  if #items == 0 then
    return say(ctx, NO_LINKS)
  end
  local s, serr = load_share()
  if not s then
    return say(ctx, "Can't load the picker: " .. tostring(serr))
  end

  -- A remote pane's dispatcher needs a way to its server: the Rex app's
  -- tunnel for ssh hosts, else a direct connection by label.
  local endpoint
  if ctx.server then
    local why
    endpoint, why = rexapi.app_socket(ctx.server, ctx.session_id)
    if not endpoint and why then
      return say(ctx, "Can't pick links here: " .. why)
    end
    endpoint = endpoint or ctx.server
  end

  local job = { open = {}, copy = {} }
  for i, it in ipairs(items) do
    local open, copy, text = commands_for(cfg, it, ctx)
    job.open[i] = open or {}
    job.copy[i] = { argv = copy or {}, text = text }
  end
  local dir, jerr = write_job(job)
  if not dir then
    return say(ctx, "Can't write the pick job: " .. tostring(jerr))
  end
  local cleanup = function()
    run.remove_job({ dir = dir })
  end

  if not ctx.server then
    local res, _, lerr =
      rexapi.new_layer(ctx, picker.request(ctx, items, cfg, s, { mode = "local", job = dir, root = ROOT }))
    if not res then
      cleanup()
      say(ctx, "Can't show the links: " .. tostring(lerr))
    end
    return
  end

  local token = new_token()
  if not token then
    cleanup()
    return say(ctx, "Can't make a token for the picker")
  end
  local res, _, lerr = rexapi.new_layer(ctx, picker.request(ctx, items, cfg, s, { mode = "remote", token = token }))
  if not res then
    cleanup()
    return say(ctx, "Can't show the links: " .. tostring(lerr))
  end
  local block = res.block_ids and res.block_ids[1]
  local ok, derr = false, "the picker has no block id"
  if block then
    ok, derr = rexapi.run({
      "perl",
      "-MPOSIX",
      "-e",
      DETACH,
      run.LOG,
      rexapi.rex_cli(),
      "-S",
      endpoint,
      "do",
      "-s",
      ctx.session_id,
      ROOT .. "bin/dispatch.lua",
      "job=" .. dir,
      "block=" .. block,
      "token=" .. token,
      "--for",
      DISPATCH_FOR,
    }, { timeout = 5 })
  end
  if not ok then
    -- Without a dispatcher a pick would do nothing: close the picker.
    rexapi.close_layer(ctx, res.layer_id)
    cleanup()
    say(ctx, "Can't start the link dispatcher: " .. tostring(derr))
  end
end

-- Validates opts and registers the pick_link and open_last_link actions.
-- Binds no keys. Errors name any unknown or invalid option.
function M.setup(opts)
  local cfg = config.build(opts)
  rex.action {
    name = "pick_link",
    title = "Pick a Link in Pane",
    description = "List the links in the focused pane in a floating picker, then open or copy one.",
    run = function(ctx)
      pick_link(ctx, cfg)
    end,
  }
  rex.action {
    name = "open_last_link",
    title = "Open Newest Link in Pane",
    description = "Open the newest link in the focused pane.",
    run = function(ctx)
      open_last_link(ctx, cfg)
    end,
  }
  return cfg
end

return M
