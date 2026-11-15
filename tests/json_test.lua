-- Tests for fzf_links/json.lua. Run from anywhere: rex do path/to/json_test.lua

local dir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or "./"
local T = dofile(dir .. "helper.lua")
local json = require "fzf_links.json"

T.eq("string", json.encode("a"), '"a"')
T.eq("escapes", json.encode('q"b\\n\n\t'), '"q\\"b\\\\n\\n\\t"')
T.eq("control char", json.encode("\1"), '"\\u0001"')
T.eq("utf-8 kept", json.encode("™ç"), '"™ç"')
T.eq("integer", json.encode(42), "42")
T.eq("float", json.encode(0.5), "0.5")
T.eq("booleans", json.encode({ true, false }), "[true,false]")
T.eq("nil", json.encode(nil), "null")
T.eq("empty table is an array", json.encode({}), "[]")
T.eq("array", json.encode({ "open", "-a", "Firefox" }), '["open","-a","Firefox"]')
T.eq("object sorted", json.encode({ b = 1, a = { "x" } }), '{"a":["x"],"b":1}')
T.raises("mixed keys", function()
  json.encode({ 1, x = 2 })
end, "object key must be a string")
T.raises("function", function()
  json.encode({ f = print })
end, "can't encode a function")
T.raises("infinite", function()
  json.encode(math.huge)
end, "not finite")
local cyc = {}
cyc.self = cyc
T.raises("cycle", function()
  json.encode(cyc)
end, "cycle")

-- Round trip through rex's own decoder when available (rex do provides rex.json).
if rex and rex.json and rex.json.decode then
  local job =
    { open = { { "open", 'https://x?a=1&b="2"' } }, copy = { { argv = { "pbcopy" }, text = "line\nnext" } }, n = 3 }
  local back = rex.json.decode(json.encode(job))
  T.eq("round trip url", back.open[1][2], job.open[1][2])
  T.eq("round trip text", back.copy[1].text, "line\nnext")
  T.eq("round trip number", back.n, 3)
end

return T.finish("json")
