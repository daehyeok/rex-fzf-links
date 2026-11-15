-- fzf_links/json.lua: a minimal JSON encoder.
--
-- The pick_link action writes the pick job (the open and copy commands it
-- built) as job.json in a private temp dir, and bin/act.lua and
-- bin/dispatch.lua read it back with rex.json.decode.
-- Only what the job needs is supported: strings, numbers, booleans, nil and
-- tables. A table with a non-empty array part (or no keys at all) is an array;
-- any other table is an object with string keys, written in sorted order so
-- the output is stable.
--
-- Pure Lua 5.1; no rex.* calls.

local M = {}

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  if next(t) == nil then
    return true
  end
  local n = #t
  if n == 0 then
    return false
  end
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
      return false
    end
  end
  return true
end

local encode

-- Encodes a table as an array or an object; errors on mixed or invalid keys.
local function encode_table(t, seen)
  if seen[t] then
    error("json: cycle in table", 0)
  end
  seen[t] = true
  local parts = {}
  if is_array(t) then
    for i = 1, #t do
      parts[i] = encode(t[i], seen)
    end
    seen[t] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(t) do
    if type(k) ~= "string" then
      error("json: object key must be a string, got " .. type(k), 0)
    end
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for i, k in ipairs(keys) do
    parts[i] = encode_string(k) .. ":" .. encode(t[k], seen)
  end
  seen[t] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

encode = function(v, seen)
  local tv = type(v)
  if v == nil then
    return "null"
  elseif tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("json: number is not finite", 0)
    end
    if v % 1 == 0 and v > -1e15 and v < 1e15 then
      return string.format("%d", v)
    end
    return string.format("%.17g", v)
  elseif tv == "string" then
    return encode_string(v)
  elseif tv == "table" then
    return encode_table(v, seen)
  end
  error("json: can't encode a " .. tv, 0)
end

-- Returns the JSON text for v. Errors on functions, cycles, non-finite
-- numbers and tables mixing array and object keys.
function M.encode(v)
  return encode(v, {})
end

return M
