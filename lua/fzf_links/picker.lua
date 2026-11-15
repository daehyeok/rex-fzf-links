-- fzf_links/picker.lua: builds the floating picker pane.
--
-- Runs in the Rex config on the client. The pane runs share/picker.sh on the
-- host of the pane the user is in, so it gets only display data (labels, URLs
-- for clickable links, preview positions). The pane closes when the script
-- exits. How it acts on a pick depends on where it runs:
--   local   it runs bin/act.lua on the job file itself;
--   remote  it sets its title to the token message (see codes.lua), which the
--           client's dispatcher sees.

local config = require "fzf_links.config"
local rexapi = require "fzf_links.rexapi"

local M = {}

M.LABEL = "links"

-- Shortens a file label with the first matching label_aliases prefix.
local function display_label(item, aliases)
  if item.kind == "file" then
    for prefix, short in pairs(aliases or {}) do
      if item.label:sub(1, #prefix + 1) == prefix .. "/" then
        return short .. "/" .. item.label:sub(#prefix + 2)
      end
    end
  end
  return item.label
end
M.display_label = display_label

-- The key hint under the search box, from the first key of each action.
function M.hint(cfg)
  local function key(action, fallback)
    return config.first_key(cfg, action) or fallback
  end
  local nth = key("open_nth", "alt-%d"):gsub("%%d", "1..9")
  return string.format(
    "%s open  %s open N  %s copy  %s context  %s close",
    key("open", "enter"),
    nth,
    key("copy", "ctrl-y"),
    key("context", "ctrl-o"),
    key("close", "esc")
  )
end

-- Returns the "KEY<TAB>ACTION" lines picker.sh turns into fzf --bind flags.
function M.binds(cfg)
  local lines = {}
  for _, b in ipairs(config.key_bindings(cfg)) do
    lines[#lines + 1] = b[1] .. "\t" .. b[2]
  end
  return table.concat(lines, "\n")
end

-- The fzf --preview-window value for cfg.preview: a raw `fzf` value as-is,
-- else the position and size with the border on the side facing the list.
local BORDERS = { up = "border-bottom", down = "border-top", left = "border-right", right = "border-left" }
function M.preview_window(cfg)
  local p = cfg.preview or {}
  if p.fzf then
    return p.fzf
  end
  local pos = p.position or "up"
  if pos == "hidden" then
    return "hidden"
  end
  return string.format("%s,%s,%s", pos, p.size or config.PREVIEW_POSITIONS[pos], BORDERS[pos])
end

-- Returns the session.new_layer request for the picker over ctx's pane.
-- share = { picker = <picker.sh text>, filter = <filter.awk text> };
-- how  = { mode = "local", job = <job dir>, root = <plugin dir> }
--     or { mode = "remote", token = <token> }.
function M.request(ctx, items, cfg, share, how)
  local a, b
  if how.mode == "local" then
    a, b = how.job, how.root
  else
    a, b = how.token, ""
  end
  local argv = {
    "sh",
    "-c",
    share.picker,
    M.LABEL,
    ctx.block_id,
    rexapi.rex_cli(),
    tostring(cfg.max_scrollback),
    share.filter,
    M.binds(cfg),
    cfg.fzf_options or "",
    cfg.context_cmd,
    M.hint(cfg),
    how.mode,
    M.preview_window(cfg),
    a,
    b,
  }
  for _, it in ipairs(items) do
    argv[#argv + 1] = display_label(it, cfg.label_aliases)
    argv[#argv + 1] = it.kind == "url" and it.target or ""
    argv[#argv + 1] = tostring(it.line_from_end or 1)
    argv[#argv + 1] = it.label
  end
  return {
    session_id = ctx.session_id,
    bounds = cfg.pane_bounds,
    focus = true,
    layout = {
      block = {
        flavor = "com.superlogical.terminal.shell",
        label = M.LABEL,
        options = { command = argv, interactive = cfg.interactive_shell },
      },
    },
  }
end

return M
