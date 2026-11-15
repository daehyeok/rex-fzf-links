-- Tests for fzf_links/run.lua. Run from anywhere: rex do path/to/run_test.lua

local dir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or "./"
local T = dofile(dir .. "helper.lua")
local run = require "fzf_links.run"

-- Logs go to a scratch file, not the user's log.
local tmp = os.tmpname()
run.LOG = tmp .. ".log"

local function exists(p)
  local f = io.open(p, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- A job dir with a job.json, like init.lua writes.
local function new_job()
  local d = tmp .. ".d" .. tostring(math.random(1e9))
  T.mkdir(d)
  local f = io.open(d .. "/job.json", "w")
  f:write("{}")
  f:close()
  return {
    dir = d,
    open = { { "opener", "https://a.example" }, {} },
    copy = { { argv = { "copier" }, text = "one" }, { argv = { "copier" }, text = "two" } },
  }
end

-- A stub exec that records its call and whether the job dir was gone by then.
local function stub(result, err)
  local s = { calls = {} }
  function s.exec(argv, opts)
    s.calls[#s.calls + 1] = { argv = argv, opts = opts, dir_gone = s.job and not exists(s.job.dir .. "/job.json") }
    return result, err
  end
  return s
end

-- open
local job = new_job()
local s = stub({ ok = true, code = 0 })
s.job = job
local ok, err = run.run(job, "open", 1, { exec = s.exec })
T.check("open ok", ok, err)
T.eq("open argv", s.calls[1] and table.concat(s.calls[1].argv, " "), "opener https://a.example")
T.eq("open timeout", s.calls[1] and s.calls[1].opts.timeout, 30)
T.check("job dir deleted before running", s.calls[1] and s.calls[1].dir_gone)
T.check("job dir removed", not exists(job.dir))

-- copy
job = new_job()
s = stub({ ok = true, code = 0 })
ok, err = run.run(job, "copy", 2, { exec = s.exec })
T.check("copy ok", ok, err)
T.eq("copy argv", s.calls[1] and s.calls[1].argv[1], "copier")
T.eq("copy stdin", s.calls[1] and s.calls[1].opts.stdin, "two")
T.eq("copy timeout", s.calls[1] and s.calls[1].opts.timeout, 10)

-- n given as a string (from rex.args)
job = new_job()
s = stub({ ok = true, code = 0 })
ok = run.run(job, "copy", "1", { exec = s.exec })
T.check("string n ok", ok)
T.eq("string n", s.calls[1] and s.calls[1].opts.stdin, "one")

-- missing command
job = new_job()
s = stub({ ok = true, code = 0 })
ok, err = run.run(job, "open", 2, { exec = s.exec })
T.check("missing command fails", not ok)
T.check("missing command not run", #s.calls == 0)
T.check("missing command message", tostring(err):find("no open command for item 2", 1, true), err)
T.check("missing command dir removed", not exists(job.dir))

-- item out of range
job = new_job()
ok, err = run.run(job, "open", 99, { exec = s.exec })
T.check("out of range fails", not ok and tostring(err):find("item 99", 1, true), err)

-- failing command
job = new_job()
s = stub({ ok = false, code = 1, stderr = "boom\n" })
ok, err = run.run(job, "open", 1, { exec = s.exec })
T.check("failing command fails", not ok)
T.eq("failing command message", err, "opener exited 1: boom")

-- exec error (command not found)
job = new_job()
s = stub(nil, "no such file")
ok, err = run.run(job, "open", 1, { exec = s.exec })
T.check("exec error fails", not ok)
T.eq("exec error message", err, "opener failed: no such file")

-- unknown action
job = new_job()
ok, err = run.run(job, "delete", 1, { exec = s.exec })
T.check("unknown action fails", not ok and tostring(err):find("unknown action", 1, true), err)

-- errors are logged
local f = io.open(run.LOG, "r")
local logged = f and f:read("*a") or ""
if f then
  f:close()
end
T.check("errors logged", logged:find("opener exited 1: boom", 1, true), logged)
os.remove(run.LOG)
os.remove(tmp)

return T.finish("run")
