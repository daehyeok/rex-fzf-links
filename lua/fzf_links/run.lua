-- fzf_links/run.lua: run item N of a pick job on the client.
--
-- Shared by bin/act.lua (local panes: the picker calls it directly) and
-- bin/dispatch.lua (remote panes: called when the picker's title message
-- arrives). Everything it may run was built on the client before the picker
-- opened; the pick only selects an entry.
--
-- The job (written by lua/fzf_links/init.lua as job.json):
--   dir      private temp dir holding job.json
--   open[n]  argv that opens item n ({} = no opener)
--   copy[n]  { argv = ..., text = ... } copying item n ({} argv = no clipboard tool)

local M = {}

M.LOG = ((os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")) .. "/rex-fzf-links.log"
M.OPEN_TIMEOUT = 30
M.COPY_TIMEOUT = 10

-- Appends one line to the log file (best effort).
function M.log(fmt, ...)
  local line = os.date("%Y-%m-%d %H:%M:%S ") .. "rex-fzf-links: " .. string.format(fmt, ...) .. "\n"
  local f = io.open(M.LOG, "a")
  if f then
    f:write(line)
    f:close()
  else
    io.stderr:write(line)
  end
end

-- Removes the job's dir and its job.json (single use).
function M.remove_job(job)
  if type(job) == "table" and type(job.dir) == "string" and job.dir ~= "" then
    os.remove(job.dir .. "/job.json")
    os.remove(job.dir)
  end
end

-- Runs action ("open" | "copy") for item n of job. Deletes the job dir first.
-- deps.exec replaces rex.exec (tests). Returns true, or false and a one-line
-- error, which is also logged.
function M.run(job, action, n, deps)
  local exec = (deps and deps.exec) or rex.exec
  M.remove_job(job)
  local function fail(fmt, ...)
    local msg = string.format(fmt, ...)
    M.log("%s", msg)
    return false, msg
  end
  if type(job) ~= "table" then
    return fail("no job")
  end
  n = tonumber(n)
  local argv, opts
  if action == "open" then
    argv, opts = (job.open or {})[n], { timeout = M.OPEN_TIMEOUT }
  elseif action == "copy" then
    local c = (job.copy or {})[n] or {}
    argv, opts = c.argv, { timeout = M.COPY_TIMEOUT, stdin = c.text or "" }
  else
    return fail("unknown action %s", tostring(action))
  end
  if type(argv) ~= "table" or #argv == 0 then
    return fail("no %s command for item %s", action, tostring(n))
  end
  local res, err = exec(argv, opts)
  if not res then
    return fail("%s failed: %s", argv[1], tostring(err))
  end
  if not res.ok then
    local stderr = tostring(res.stderr or ""):gsub("%s+$", ""):gsub("\n", " ")
    return fail("%s exited %s%s", argv[1], tostring(res.code), stderr ~= "" and (": " .. stderr) or "")
  end
  return true
end

return M
