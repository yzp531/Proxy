-- PAC 模式读写接口。
--   GET  /api/mode                      -> {"ok":true,"mode":"split","token_required":true}
--   POST /api/mode  mode=direct&token=X -> 切换模式
-- 挂载点：location = /api/mode
local ROOT       = "/www/wwwroot/proxy.i-xx.top"
local MODE_FILE  = ROOT .. "/pac/mode.txt"
local TOKEN_FILE = ROOT .. "/pac/token.txt"

local MODES = { split = true, direct = true, global = true }
local DEFAULT = "split"

local function read_first_line(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local line = fh:read("*l")
    fh:close()
    return line
end

local function arg(name)
    local v = ngx.req.get_uri_args()[name]
    if v == nil and ngx.req.get_method() == "POST" then
        ngx.req.read_body()
        local post = ngx.req.get_post_args()
        if post then v = post[name] end
    end
    if type(v) == "table" then v = v[1] end
    if type(v) ~= "string" then return nil end
    return v
end

local function current_mode()
    local m = read_first_line(MODE_FILE)
    if not m or not MODES[m] then return DEFAULT end
    return m
end

local function required_token()
    local t = read_first_line(TOKEN_FILE)
    if t == nil or t == "" then return nil end
    return t
end

ngx.header["Content-Type"] = "application/json; charset=utf-8"
ngx.header["Cache-Control"] = "no-store"

local want = arg("mode")

-- 读取当前模式
if want == nil then
    local need = required_token() ~= nil
    ngx.say('{"ok":true,"mode":"' .. current_mode() ..
            '","token_required":' .. (need and "true" or "false") .. '}')
    return
end

-- 切换模式
if not MODES[want] then
    ngx.status = 400
    ngx.say('{"ok":false,"error":"unknown mode"}')
    return
end

local token = required_token()
if token ~= nil and arg("token") ~= token then
    ngx.status = 403
    ngx.say('{"ok":false,"error":"token required"}')
    return
end

local fh = io.open(MODE_FILE, "w")
if not fh then
    ngx.status = 500
    ngx.say('{"ok":false,"error":"cannot write mode file"}')
    return
end
fh:write(want .. "\n")
fh:close()

ngx.say('{"ok":true,"mode":"' .. want .. '"}')
