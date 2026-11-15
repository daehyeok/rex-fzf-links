-- Tests for fzf_links/codes.lua. Run from anywhere: rex do path/to/codes_test.lua

local dir = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or "./"
local T = dofile(dir .. "helper.lua")
local codes = require "fzf_links.codes"

local TOK = "0123456789abcdef"
local OTHER = "ffffffffffffffff"

-- encode
T.eq("open 1", codes.encode(TOK, "open", 1), "rfl:" .. TOK .. ":open:1")
T.eq("copy 2", codes.encode(TOK, "copy", 2), "rfl:" .. TOK .. ":copy:2")
T.eq("open 137 (past 60)", codes.encode(TOK, "open", 137), "rfl:" .. TOK .. ":open:137")
T.eq("open 0 invalid", codes.encode(TOK, "open", 0), nil)
T.eq("fraction invalid", codes.encode(TOK, "open", 1.5), nil)
T.eq("no n", codes.encode(TOK, "open"), nil)
T.eq("unknown action", codes.encode(TOK, "delete", 1), nil)
T.eq("cancel is not a message", codes.encode(TOK, "cancel", 1), nil)
T.eq("short token", codes.encode("abc", "open", 1), nil)
T.eq("long token", codes.encode(TOK .. "00", "open", 1), nil)
T.eq("upper-case token", codes.encode(TOK:upper(), "open", 1), nil)

-- decode
local function dec(title, tok)
  local a, n = codes.decode(title, tok or TOK)
  return tostring(a) .. " " .. tostring(n)
end
T.eq("decode open", dec(codes.encode(TOK, "open", 3)), "open 3")
T.eq("decode copy", dec(codes.encode(TOK, "copy", 4)), "copy 4")
T.eq("decode past 60", dec(codes.encode(TOK, "open", 199)), "open 199")
T.eq("decode 1000", dec("rfl:" .. TOK .. ":copy:1000"), "copy 1000")
T.eq("wrong token", dec(codes.encode(OTHER, "open", 2)), "nil nil")
T.eq("token prefix only", dec("rfl:" .. TOK), "nil nil")
T.eq("no n", dec("rfl:" .. TOK .. ":open:"), "nil nil")
T.eq("malformed n", dec("rfl:" .. TOK .. ":open:x"), "nil nil")
T.eq("zero n", dec("rfl:" .. TOK .. ":open:0"), "nil nil")
T.eq("negative n", dec("rfl:" .. TOK .. ":open:-1"), "nil nil")
T.eq("unknown action", dec("rfl:" .. TOK .. ":rm:1"), "nil nil")
T.eq("trailing text", dec("rfl:" .. TOK .. ":open:1 x"), "nil nil")
T.eq("trailing newline", dec("rfl:" .. TOK .. ":open:1\n"), "nil nil")
T.eq("leading text", dec("x rfl:" .. TOK .. ":open:1"), "nil nil")
T.eq("old prefix", dec("rex-fzf-links:" .. TOK .. ":open:1"), "nil nil")
T.eq("plain title", dec("zsh"), "nil nil")
T.eq("nil title", dec(nil), "nil nil")
T.eq("bad token arg", dec(codes.encode(TOK, "open", 1), "nope"), "nil nil")

return T.finish("codes")
