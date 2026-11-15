-- Tests for fzf_links/config.lua. Run from anywhere: rex do path/to/config_test.lua

local dir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or "./"
local T = dofile(dir .. "helper.lua")
local config = require "fzf_links.config"

-- Defaults and validation
local cfg = config.build({})
T.eq("default max_scrollback", cfg.max_scrollback, 524288)
T.eq("default max_items", cfg.max_items, 200)
T.eq("custom max_items", config.build({ max_items = 20 }).max_items, 20)
T.raises("max_items 0", function()
  config.build({ max_items = 0 })
end, "max_items must be a positive integer")
T.raises("max_items fraction", function()
  config.build({ max_items = 1.5 })
end, "max_items must be a positive integer")
T.raises("max_items string", function()
  config.build({ max_items = "9" })
end, "max_items must be a positive integer")
T.eq("default patterns empty", #cfg.patterns, 0)
T.eq("default context_cmd is less", cfg.context_cmd, config.DEFAULT_CONTEXT_CMD)
T.raises("unknown option", function()
  config.build({ prefix = "ctrl+b" })
end, "unknown option 'prefix'")
T.raises("removed option short_links", function()
  config.build({ short_links = {} })
end, "'short_links'")
T.raises("bad max_scrollback", function()
  config.build({ max_scrollback = 0 })
end, "max_scrollback")
T.raises("bad pattern", function()
  config.build({ patterns = { { match = "x" } } })
end, "patterns[1]")
T.raises("bad open_cmd", function()
  config.build({ open_cmd = "open" })
end, "open_cmd")
T.raises("bad host field", function()
  config.build({ hosts = { a = { mount = 1 } } })
end, "hosts.a: unknown field 'mount'")
T.raises("bad key action", function()
  config.build({ keys = { jump = "x" } })
end, "unknown action 'jump'")
T.raises("bad nine-key list", function()
  config.build({ keys = { open_nth = { { "a", "b" } } } })
end, "keys.open_nth")
T.eq("interactive shell on by default", config.build({}).interactive_shell, true)
T.raises("bad interactive_shell", function()
  config.build({ interactive_shell = "yes" })
end, "interactive_shell must be true or false")
T.raises("bad pane_bounds", function()
  config.build({ pane_bounds = { 1, 2 } })
end, "pane_bounds")

-- preview
local function pv(p)
  return config.build({ preview = p }).preview
end
T.eq("default preview up", cfg.preview.position, "up")
T.eq("default preview size", cfg.preview.size, "60%")
T.eq("down default size", pv({ position = "down" }).size, "60%")
T.eq("right default size", pv({ position = "right" }).size, "50%")
T.eq("left default size", pv({ position = "left" }).size, "50%")
T.eq("hidden has no size", pv({ position = "hidden" }).size, nil)
T.eq("size alone keeps up", pv({ size = "40%" }).position, "up")
T.eq("percent size", pv({ position = "down", size = "40%" }).size, "40%")
T.eq("number size", pv({ position = "right", size = 70 }).size, "70")
T.eq("digit string size", pv({ position = "right", size = "70" }).size, "70")
T.eq("raw fzf kept", pv({ fzf = "right,50%,<50(up)" }).fzf, "right,50%,<50(up)")
T.raises("preview not table", function()
  config.build({ preview = "right" })
end, "preview must be a table")
T.raises("bad position", function()
  pv({ position = "top" })
end, "preview.position")
T.raises("unknown preview field", function()
  pv({ side = "right" })
end, "preview.side")
T.raises("size 0%", function()
  pv({ size = "0%" })
end, "preview.size")
T.raises("size 100%", function()
  pv({ size = "100%" })
end, "preview.size")
T.raises("size x", function()
  pv({ size = "x" })
end, "preview.size")
T.raises("size fraction", function()
  pv({ size = 1.5 })
end, "preview.size")
T.raises("size 0", function()
  pv({ size = 0 })
end, "preview.size")
T.raises("empty fzf", function()
  pv({ fzf = "" })
end, "preview.fzf")
T.raises("fzf not string", function()
  pv({ fzf = { "right" } })
end, "preview.fzf")
-- the README's preview examples
T.eq(
  "README side example",
  config.build({ preview = { position = "right" }, pane_bounds = { 0.03, 0.06, 0.94, 0.88 } }).preview.size,
  "50%"
)
T.eq(
  "README raw example",
  pv({ fzf = "right,50%,border-left,<50(up,60%,border-bottom)" }).fzf,
  "right,50%,border-left,<50(up,60%,border-bottom)"
)

-- Host entry selection
local hosts_cfg = config.build({
  hosts = {
    ["local"] = { open_cmd = { "local-open" } },
    devbox = { match = { "devbox", "devbox.example.net" } },
    lab = { match = { ["lab-1"] = true } },
    solo = { match = "solo.example.net" },
  },
})
T.eq("local pane uses hosts.local", config.host_for(hosts_cfg, nil), hosts_cfg.hosts["local"])
T.eq("name selects entry", config.host_for(hosts_cfg, "devbox"), hosts_cfg.hosts.devbox)
T.eq("match list selects entry", config.host_for(hosts_cfg, "devbox.example.net"), hosts_cfg.hosts.devbox)
T.eq("match set selects entry", config.host_for(hosts_cfg, "lab-1"), hosts_cfg.hosts.lab)
T.eq("match string selects entry", config.host_for(hosts_cfg, "solo.example.net"), hosts_cfg.hosts.solo)
T.eq("unknown host has no entry", config.host_for(hosts_cfg, "other"), nil)

-- File acceptance
local exists = function(p)
  return p == "/tmp/there"
end
local r_local = config.file_resolver(config.build({}), {}, exists)
T.eq("local pane accepts existing file", r_local("/tmp/there"), "/tmp/there")
T.eq("local pane rejects missing file", r_local("/tmp/missing"), nil)
T.eq(
  "remote pane without rules accepts nothing",
  config.file_resolver(config.build({}), { server = "devbox" }, exists),
  nil
)
local mount_cfg = config.build({
  hosts = {
    devbox = {
      resolve_file = function(path)
        local rest = path:match("^/home/me/share(/.*)$")
        return rest and ("/Volumes/share" .. rest) or nil
      end,
    },
  },
})
local r_mount = config.file_resolver(mount_cfg, { server = "devbox" }, exists)
T.eq("remote mount maps path", r_mount("/home/me/share/a.md"), "/Volumes/share/a.md")
T.eq("remote mount rejects outside", r_mount("/etc/hosts"), nil)

-- Client defaults
local mac = config.client_defaults()
T.eq("macOS opener", table.concat(mac.open, " "), "open")
T.eq("macOS clipboard", table.concat(mac.copy, " "), "pbcopy")
T.check("fresh tables each call", config.client_defaults().open ~= mac.open)

-- Command resolution: host > top-level > client default, nil falls through
local url = { kind = "url", target = "https://x" }
local file = { kind = "file", target = "/Volumes/share/a.md" }
local cmd_cfg = config.build({
  open_cmd = { "open", "-a", "Firefox" },
  hosts = {
    devbox = {
      open_cmd = function(item)
        if item.kind == "file" then
          return { "mnt-open" }
        end
      end,
    },
  },
})
T.eq(
  "host opener for files",
  table.concat(config.command_for(cmd_cfg, "open_cmd", file, { server = "devbox" }, { "open" }), " "),
  "mnt-open"
)
T.eq(
  "host nil falls to top-level",
  table.concat(config.command_for(cmd_cfg, "open_cmd", url, { server = "devbox" }, { "open" }), " "),
  "open -a Firefox"
)
T.eq(
  "local uses top-level",
  table.concat(config.command_for(cmd_cfg, "open_cmd", url, {}, { "open" }), " "),
  "open -a Firefox"
)
T.eq(
  "falls to client default",
  table.concat(config.command_for(config.build({}), "copy_cmd", url, {}, { "pbcopy" }), " "),
  "pbcopy"
)
T.eq("nothing anywhere", config.command_for(config.build({}), "copy_cmd", url, {}, nil), nil)
local fn_cfg = config.build({
  copy_cmd = function()
    return nil
  end,
})
T.eq("function returning nil falls through", config.command_for(fn_cfg, "copy_cmd", url, {}, { "pbcopy" })[1], "pbcopy")
local returned = config.command_for(cmd_cfg, "open_cmd", url, {}, nil)
returned[#returned + 1] = "target"
T.eq("returned argv is a copy", #cmd_cfg.open_cmd, 3)

-- Key bindings
local function bindings_of(c)
  local out = {}
  for _, b in ipairs(config.key_bindings(c)) do
    out[#out + 1] = b[1] .. "=" .. b[2]
  end
  return " " .. table.concat(out, " ") .. " "
end
local def = bindings_of(config.build({}))
T.check("default enter opens", def:find(" enter=open ", 1, true), def)
T.check("default ctrl-y copies", def:find(" ctrl-y=copy ", 1, true), def)
T.check("default ctrl-o context", def:find(" ctrl-o=context ", 1, true), def)
T.check("default alt-2 opens 2", def:find(" alt-2=nth:2 ", 1, true), def)
T.check("no plugin default for up", not def:find("=up ", 1, true), def)
local custom = bindings_of(config.build({
  keys = {
    up = "ctrl-k",
    copy = { "ctrl-y", "alt-c" },
    open_nth = { "alt-%d", { "¡", "™", "£", "¢", "∞", "§", "¶", "•", "ª" } },
  },
}))
T.check("custom up", custom:find(" ctrl-k=up ", 1, true), custom)
T.check("list of copy keys", custom:find(" ctrl-y=copy ", 1, true) and custom:find(" alt-c=copy ", 1, true), custom)
T.check("nine-key list", custom:find(" ™=nth:2 ", 1, true) and custom:find(" alt-2=nth:2 ", 1, true), custom)
T.eq("first key of open_nth", config.first_key(config.build({}), "open_nth"), "alt-%d")

return T.finish("config")
