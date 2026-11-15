-- bin/act.lua: open or copy item N of a pick job, for a picker over a local
-- pane. The picker runs on the client, so it calls this directly:
--
--   rex do bin/act.lua job=<job dir> action=open|copy n=<N>
--
-- The job dir holds job.json, written by lua/fzf_links/init.lua with every
-- command already built; this only selects one (see lua/fzf_links/run.lua).
-- Exits non-zero with a one-line error when nothing could be run.

local src = debug.getinfo(1, "S").source
local dir = src:match("^@?(.*[/\\])") or "./"
package.path = dir .. "../lua/?.lua;" .. dir .. "../lua/?/init.lua;" .. package.path

local run = require "fzf_links.run"

local args = rex.args or {}
if type(args.job) ~= "string" or args.job == "" then
  error("no job given", 0)
end

local job
local f = io.open(args.job .. "/job.json", "r")
if f then
  local ok, decoded = pcall(rex.json.decode, f:read("*a"))
  f:close()
  if ok and type(decoded) == "table" then
    job = decoded
  end
end
if not job then
  run.remove_job({ dir = args.job })
  run.log("can't read the job in %s", args.job)
  error("the pick has expired; open the picker again", 0)
end
job.dir = args.job

local ok, err = run.run(job, args.action, args.n)
if not ok then
  error(err, 0)
end
