-- 按当前模式返回对应的 PAC 文件。模式由 /api/mode 切换，状态存在 pac/mode.txt。
-- 挂载点：location = /pac
local ROOT = "/www/wwwroot/proxy.i-xx.top"
local DEFAULT = "split"

local FILES = {
    split  = ROOT .. "/proxy.pac",   -- 国内直连，海外走代理
    direct = ROOT .. "/direct.pac",  -- 全部直连
    global = ROOT .. "/global.pac"   -- 全部走代理
}

local function read_first_line(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local line = fh:read("*l")
    fh:close()
    return line
end

local mode = read_first_line(ROOT .. "/pac/mode.txt") or DEFAULT
if not FILES[mode] then mode = DEFAULT end

local fh = io.open(FILES[mode], "r")
if not fh then
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "text/plain; charset=utf-8"
    ngx.say("PAC file not found: " .. tostring(FILES[mode]))
    return
end
local body = fh:read("*a")
fh:close()

ngx.header["Content-Type"] = "application/x-ns-proxy-autoconfig"
ngx.header["Cache-Control"] = "no-cache, no-store, must-revalidate"
ngx.header["X-PAC-Mode"] = mode
ngx.print(body)
