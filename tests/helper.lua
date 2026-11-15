-- tests/helper.lua: shared setup for the plugin's tests.
--
-- Each test file loads it with dofile(<its own dir> .. "helper.lua"). It puts
-- the plugin's lua/ directory on package.path (relative to this file, so tests
-- run from any working directory) and returns a tiny check/finish harness.
-- Run a test with: rex do path/to/<name>_test.lua, or plain Lua 5.1/LuaJIT:
-- lua path/to/<name>_test.lua

local src = debug.getinfo(1, "S").source
local dir = src:match("^@?(.*[/\\])") or "./"
package.path = dir .. "../lua/?.lua;" .. dir .. "../lua/?/init.lua;" .. package.path

local T = { passes = 0, failures = {} }

-- Records a check; detail is shown when it fails.
function T.check(name, ok, detail)
  if ok then
    T.passes = T.passes + 1
  else
    T.failures[#T.failures + 1] = name .. (detail ~= nil and (": " .. tostring(detail)) or "")
  end
end

-- Checks got == want, showing both on failure.
function T.eq(name, got, want)
  T.check(name, got == want, string.format("want %s, got %s", tostring(want), tostring(got)))
end

-- Checks that fn() raises an error whose message contains `needle`.
function T.raises(name, fn, needle)
  local ok, err = pcall(fn)
  T.check(name, not ok and tostring(err):find(needle, 1, true) ~= nil, ok and "no error" or tostring(err))
end

-- Creates a directory (and its parents): rex.exec under `rex do`, which has
-- no os.execute; os.execute under plain Lua.
function T.mkdir(path)
  if rex and rex.exec then
    rex.exec({ "mkdir", "-p", path })
  else
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
  end
end

-- Prints the results; raises (so `rex do` exits non-zero) on any failure.
function T.finish(suite)
  for _, f in ipairs(T.failures) do
    print("FAIL: " .. f)
  end
  print(string.format("%s: %d passed, %d failed", suite, T.passes, #T.failures))
  if #T.failures > 0 then
    error(#T.failures .. " " .. suite .. " test(s) failed", 0)
  end
  return "ok"
end

return T
