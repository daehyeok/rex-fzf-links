-- fzf_links/config.lua: options, their defaults, and how they resolve.
--
-- Everything here is pure Lua 5.1 with no rex.* calls: the caller passes in
-- whatever needs the system (a file-exists check),
-- so the whole option model is tested without a running session.
--
-- Resolution order for a pane on server S (nil for a local pane):
--   host entry  = hosts["local"] when S is nil, else hosts[S], else the entry
--                 whose `match` holds S
--   open/copy   = host entry's command  >  top-level command  >  client default
--                 (a function returning nil falls through to the next level)
--   files       = host entry's resolve_file; without one, local panes accept
--                 existing files and remote panes accept none

local M = {}

-- The dialog actions `keys` may bind. up/down/close have no plugin default:
-- fzf's own keys (arrows, ctrl-p/ctrl-n, esc, ...) already do them.
M.KEY_ACTIONS = { "up", "down", "open", "copy", "context", "close", "open_nth" }

local DEFAULT_KEYS = {
  open = { "enter" },
  copy = { "ctrl-y" },
  context = { "ctrl-o" },
  open_nth = { "alt-%d" },
}

-- Default context viewer: run on the pane's host with LINK_FILE, LINK_LINE
-- and LINK_MATCH set; -j.5 puts the link's line in the middle of the screen.
M.DEFAULT_CONTEXT_CMD = 'less -R -j.5 +"${LINK_LINE}g" "$LINK_FILE"'

local function defaults()
  return {
    max_scrollback = 512 * 1024,
    max_items = 200,
    patterns = {},
    open_cmd = nil,
    copy_cmd = nil,
    hosts = {},
    label_aliases = {},
    keys = {},
    fzf_options = "",
    context_cmd = M.DEFAULT_CONTEXT_CMD,
    pane_bounds = { 0.1, 0.08, 0.8, 0.84 },
    preview = { position = "up" },
    -- Start the picker with the user's interactive shell environment (e.g.
    -- ~/.zshrc), so fzf and less are found on the same PATH as in their
    -- terminals.
    interactive_shell = true,
  }
end

-- Where the preview can sit, and its default size there.
M.PREVIEW_POSITIONS = { up = "60%", down = "60%", left = "50%", right = "50%", hidden = false }

local function fail(fmt, ...)
  error("rex-fzf-links: " .. string.format(fmt, ...), 0)
end

local function is_list_of(t, kind)
  if type(t) ~= "table" then
    return false
  end
  for k, v in pairs(t) do
    if type(k) ~= "number" or type(v) ~= kind then
      return false
    end
  end
  return true
end

local function check_cmd(name, v)
  if v ~= nil and type(v) ~= "function" and not (is_list_of(v, "string") and #v > 0) then
    fail("%s must be a non-empty list of strings or a function", name)
  end
end

-- One checker per option; each errors with a message naming the option.
local CHECKS = {
  max_scrollback = function(v)
    if type(v) ~= "number" or v < 1 then
      fail("max_scrollback must be a positive number")
    end
  end,
  max_items = function(v)
    if type(v) ~= "number" or v < 1 or v % 1 ~= 0 then
      fail("max_items must be a positive integer")
    end
  end,
  patterns = function(v)
    if type(v) ~= "table" then
      fail("patterns must be a list")
    end
    for i, p in ipairs(v) do
      if type(p) ~= "table" or type(p.match) ~= "string" or p.match == "" or type(p.url) ~= "string" or p.url == "" then
        fail("patterns[%d] needs non-empty `match` and `url` strings", i)
      end
    end
  end,
  open_cmd = function(v)
    check_cmd("open_cmd", v)
  end,
  copy_cmd = function(v)
    check_cmd("copy_cmd", v)
  end,
  hosts = function(v)
    if type(v) ~= "table" then
      fail("hosts must be a table")
    end
    for name, h in pairs(v) do
      if type(name) ~= "string" or type(h) ~= "table" then
        fail("hosts must map names to tables")
      end
      for k in pairs(h) do
        if k ~= "match" and k ~= "resolve_file" and k ~= "open_cmd" and k ~= "copy_cmd" then
          fail("hosts.%s: unknown field '%s'", name, tostring(k))
        end
      end
      if h.match ~= nil and type(h.match) ~= "table" and type(h.match) ~= "string" then
        fail("hosts.%s.match must be a label or a list of labels", name)
      end
      if h.resolve_file ~= nil and type(h.resolve_file) ~= "function" then
        fail("hosts.%s.resolve_file must be a function", name)
      end
      check_cmd("hosts." .. name .. ".open_cmd", h.open_cmd)
      check_cmd("hosts." .. name .. ".copy_cmd", h.copy_cmd)
    end
  end,
  label_aliases = function(v)
    if type(v) ~= "table" then
      fail("label_aliases must be a table")
    end
  end,
  keys = function(v)
    if type(v) ~= "table" then
      fail("keys must be a table")
    end
    local known = {}
    for _, a in ipairs(M.KEY_ACTIONS) do
      known[a] = true
    end
    for action, keys in pairs(v) do
      if not known[action] then
        fail("keys: unknown action '%s'", tostring(action))
      end
      if type(keys) == "table" then
        for _, k in ipairs(keys) do
          local nine = action == "open_nth" and type(k) == "table"
          if not (type(k) == "string" or (nine and #k == 9 and is_list_of(k, "string"))) then
            fail(
              "keys.%s must be a key or a list of keys%s",
              action,
              action == "open_nth" and " (or lists of nine keys)" or ""
            )
          end
        end
      elseif type(keys) ~= "string" then -- a string is one key
        fail("keys.%s must be a key or a list of keys", action)
      end
    end
  end,
  fzf_options = function(v)
    if type(v) ~= "string" then
      fail("fzf_options must be a string")
    end
  end,
  context_cmd = function(v)
    if type(v) ~= "string" or v == "" then
      fail("context_cmd must be a non-empty string")
    end
  end,
  interactive_shell = function(v)
    if type(v) ~= "boolean" then
      fail("interactive_shell must be true or false")
    end
  end,
  pane_bounds = function(v)
    if not is_list_of(v, "number") or #v ~= 4 then
      fail("pane_bounds must be four numbers { x, y, width, height }")
    end
  end,
  preview = function(v)
    if type(v) ~= "table" then
      fail("preview must be a table")
    end
    for k in pairs(v) do
      if k ~= "position" and k ~= "size" and k ~= "fzf" then
        fail("preview.%s: unknown field", tostring(k))
      end
    end
    if v.position ~= nil and M.PREVIEW_POSITIONS[v.position] == nil then
      fail("preview.position must be up, down, left, right or hidden")
    end
    local size = v.size
    if size ~= nil then
      local pct, n
      if type(size) == "string" then
        pct = size:match("^(%d+)%%$")
        n = size:match("^%d+$")
        pct, n = pct and tonumber(pct), n and tonumber(n)
      elseif type(size) == "number" then
        n = size
      end
      if not ((pct and pct >= 1 and pct <= 99) or (n and n >= 1 and n % 1 == 0)) then
        fail("preview.size must be a percentage (1%% to 99%%) or a positive whole number")
      end
    end
    if v.fzf ~= nil and (type(v.fzf) ~= "string" or v.fzf == "") then
      fail("preview.fzf must be a non-empty string")
    end
  end,
}

-- Returns the preview with its defaults filled in: { position, size, fzf }.
local function resolve_preview(v)
  local position = v.position or "up"
  local size = v.size
  if size == nil then
    size = M.PREVIEW_POSITIONS[position] or nil
  end
  return { position = position, size = size and tostring(size) or nil, fzf = v.fzf }
end

-- Validates opts and returns the full config (defaults filled in).
-- Errors name the first unknown or invalid option.
function M.build(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    fail("setup expects a table of options")
  end
  for k in pairs(opts) do
    if not CHECKS[k] then
      fail("unknown option '%s'", tostring(k))
    end
  end
  local cfg = defaults()
  for k, v in pairs(opts) do
    CHECKS[k](v)
    cfg[k] = v
  end
  cfg.preview = resolve_preview(cfg.preview)
  return cfg
end

-- Returns the host entry for a pane on `server` (nil = local pane), or nil.
function M.host_for(cfg, server)
  local hosts = cfg.hosts or {}
  if server == nil then
    return hosts["local"]
  end
  if hosts[server] then
    return hosts[server]
  end
  for _, h in pairs(hosts) do
    local m = h.match
    if m == server then
      return h
    end
    if type(m) == "table" then
      if m[server] == true then
        return h
      end -- set form: { label = true }
      for _, label in ipairs(m) do
        if label == server then
          return h
        end
      end
    end
  end
  return nil
end

-- Returns a resolve_file(path) -> client_path|nil function for ctx's pane, or
-- nil when the pane's files can't be opened on the client.
-- exists(path) -> bool is the client-side file check used for local panes.
function M.file_resolver(cfg, ctx, exists)
  local host = M.host_for(cfg, ctx.server)
  if host and host.resolve_file then
    return function(path)
      return host.resolve_file(path, ctx)
    end
  end
  if ctx.server == nil then
    return function(path)
      if exists(path) then
        return path
      end
    end
  end
  return nil
end

-- The client's default opener and clipboard: the macOS tools. The client is
-- the macOS Rex app; other clients set open_cmd and copy_cmd.
-- Returns { open = argv, copy = argv }.
function M.client_defaults()
  return { open = { "open" }, copy = { "pbcopy" } }
end

local function copy_list(t)
  local out = {}
  for i, v in ipairs(t) do
    out[i] = v
  end
  return out
end

-- Returns the argv prefix for `which` ("open_cmd" | "copy_cmd") for item in
-- ctx's pane, or nil when no level provides one. client_default is the argv
-- from client_defaults. The caller appends the target (open) or feeds the
-- text on stdin (copy).
function M.command_for(cfg, which, item, ctx, client_default)
  local host = M.host_for(cfg, ctx.server)
  local levels = { host and host[which], cfg[which] }
  for i = 1, 2 do
    local v = levels[i]
    if type(v) == "function" then
      v = v(item, ctx)
    end
    if type(v) == "table" and #v > 0 then
      return copy_list(v)
    end
  end
  return client_default and copy_list(client_default) or nil
end

-- Returns the dialog's key bindings as a list of { key, action }, where
-- action is "up" | "down" | "open" | "copy" | "context" | "close" | "nth:N".
-- A configured action replaces the plugin's default keys for that action;
-- fzf's own keys stay either way.
function M.key_bindings(cfg)
  local keys = cfg.keys or {}
  local out = {}
  for _, action in ipairs(M.KEY_ACTIONS) do
    local v = keys[action]
    if v == nil then
      v = DEFAULT_KEYS[action]
    end
    if type(v) == "string" then
      v = { v }
    end
    for _, k in ipairs(v or {}) do
      if action == "open_nth" then
        for n = 1, 9 do
          local key = type(k) == "table" and k[n] or k:gsub("%%d", tostring(n))
          out[#out + 1] = { key, "nth:" .. n }
        end
      else
        out[#out + 1] = { k, action }
      end
    end
  end
  return out
end

-- Returns the first configured key of an action, for the hint line.
function M.first_key(cfg, action)
  local v = (cfg.keys or {})[action]
  if v == nil then
    v = DEFAULT_KEYS[action]
  end
  if type(v) == "table" then
    v = v[1]
  end
  if type(v) == "table" then
    v = v[1]
  end
  return v
end

return M
