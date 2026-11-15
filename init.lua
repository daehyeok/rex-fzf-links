-- rex-fzf-links entry point for `require("plugins.rex-fzf-links")`.
--
-- Clone the repository into the `plugins` folder of your Rex config
-- (~/.config/rex/plugins/rex-fzf-links); this file puts the plugin's lua/
-- directory on package.path and returns the fzf_links module.

local dir = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$")) or "."
local lua_dir = dir .. "/lua/"
if not package.path:find(lua_dir, 1, true) then
  package.path = lua_dir .. "?.lua;" .. lua_dir .. "?/init.lua;" .. package.path
end
return require("fzf_links")
