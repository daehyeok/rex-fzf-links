-- Tests for fzf_links/picker.lua. Run from anywhere: rex do path/to/picker_test.lua

local dir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or "./"
local T = dofile(dir .. "helper.lua")
local config = require "fzf_links.config"
local picker = require "fzf_links.picker"

local cfg = config.build({})
local ctx = { session_id = "s1", block_id = "b1" }
local share = { picker = "PICKER", filter = "FILTER" }
local items = {
  { kind = "url", label = "https://a.example", target = "https://a.example", line_from_end = 3 },
  { kind = "file", label = "/tmp/x.txt", target = "/tmp/x.txt", line_from_end = 1 },
}

-- argv layout: sh -c PICKER links, then 8 fixed fields, then mode, the
-- preview window, the mode's two fields, then 4 fields per item.
local MODE = 13
local PREVIEW = MODE + 1

local function request(how)
  local r = picker.request(ctx, items, cfg, share, how)
  return r, r.layout.block.options.command
end

local r, argv = request({ mode = "local", job = "/tmp/job.1", root = "/plugin/" })
T.eq("starts with sh -c", argv[1] .. " " .. argv[2] .. " " .. argv[3], "sh -c PICKER")
T.eq("block arg", argv[5], "b1")
T.eq("local mode", argv[MODE], "local")
T.eq("local job path", argv[MODE + 2], "/tmp/job.1")
T.eq("local plugin root", argv[MODE + 3], "/plugin/")
T.eq("first item label", argv[MODE + 4], "https://a.example")
T.eq("first item url", argv[MODE + 5], "https://a.example")
T.eq("second item has no url", argv[MODE + 9], "")
T.eq("item count", #argv, MODE + 3 + 4 * #items)
T.eq("default preview window", argv[PREVIEW], "up,60%,border-bottom")
T.eq("no exit option (pane closes on exit)", r.layout.block.options.exit, nil)
T.eq("session", r.session_id, "s1")
T.check("focused", r.focus == true)
T.eq("reads the interactive startup files", r.layout.block.options.interactive, true)
local plain = picker.request(
  ctx,
  items,
  config.build({ interactive_shell = false }),
  share,
  { mode = "local", job = "/j", root = "/p/" }
)
T.eq("interactive_shell = false", plain.layout.block.options.interactive, false)

r, argv = request({ mode = "remote", token = "0123456789abcdef" })
T.eq("remote mode", argv[MODE], "remote")
T.eq("remote token", argv[MODE + 2], "0123456789abcdef")
T.eq("remote has no root", argv[MODE + 3], "")
T.eq("remote item count", #argv, MODE + 3 + 4 * #items)
T.eq("remote: no exit option", r.layout.block.options.exit, nil)
for i, v in ipairs(argv) do
  if v:find("/tmp/job", 1, true) then
    T.check("remote argv has no job path", false, i)
  end
end

-- Preview window per position
local function pw(p)
  return picker.preview_window(config.build({ preview = p }))
end
T.eq("preview up", pw({ position = "up" }), "up,60%,border-bottom")
T.eq("preview down", pw({ position = "down", size = "40%" }), "down,40%,border-top")
T.eq("preview left", pw({ position = "left" }), "left,50%,border-right")
T.eq("preview right", pw({ position = "right", size = 70 }), "right,70,border-left")
T.eq("preview hidden", pw({ position = "hidden" }), "hidden")
T.eq("raw fzf wins", pw({ position = "left", fzf = "right,50%,<50(up)" }), "right,50%,<50(up)")
cfg = config.build({ preview = { position = "right" } })
local rargv = select(2, request({ mode = "remote", token = "t" }))
T.eq("preview window passed", rargv[PREVIEW], "right,50%,border-left")

-- Move keys: configured up/down keys reach picker.sh as "up"/"down", which it
-- binds to its scrolling `move` script along with fzf's own move keys.
local binds = "\n" .. picker.binds(config.build({ keys = { up = "alt-k", down = { "alt-j" } } })) .. "\n"
T.check("configured up key passed", binds:find("\nalt-k\tup\n", 1, true), binds)
T.check("configured down key passed", binds:find("\nalt-j\tdown\n", 1, true), binds)

return T.finish("picker")
