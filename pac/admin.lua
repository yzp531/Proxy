-- PAC 信息与维护接口（挂载点：location = /api/pac）
--   GET  /api/pac                              -> 当前 PAC 信息（JSON）
--   POST /api/pac  action=set-proxy&proxy=IP:端口
--   POST /api/pac  action=update               -> 后台更新国内域名名单
-- 实际的文件读写与渲染都交给 pac/tools.py，保证只有一个渲染入口。
local PAC   = "/www/wwwroot/proxy.i-xx.top/pac"
local PY    = "/usr/bin/python3"
local TOOLS = PAC .. "/tools.py"

local function run(cmd)
    local fh = io.popen(cmd .. " 2>&1")
    if not fh then return nil end
    local out = fh:read("*a")
    fh:close()
    return out
end

local function reply(body, status)
    ngx.status = status or ngx.HTTP_OK
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.print(body)
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

local method = ngx.req.get_method()

-- 读取信息
if method ~= "POST" then
    local out = run(PY .. " " .. TOOLS .. " info")
    if not out or out == "" then
        reply('{"ok":false,"error":"无法执行 tools.py"}', ngx.HTTP_INTERNAL_SERVER_ERROR)
        return
    end
    reply(out)
    return
end

local action = arg("action")

-- 修改代理地址
if action == "set-proxy" then
    local addr = arg("proxy")
    if not addr or addr == "" or #addr > 253 or not addr:match("^[%w%.:_%-]+$") then
        reply('{"ok":false,"error":"代理地址不合法"}', ngx.HTTP_BAD_REQUEST)
        return
    end
    local out = run(PY .. " " .. TOOLS .. " set-proxy '" .. addr .. "'")
    if not out or out == "" then
        reply('{"ok":false,"error":"渲染失败"}', ngx.HTTP_INTERNAL_SERVER_ERROR)
        return
    end
    reply(out)
    return
end

-- 后台更新国内域名名单
if action == "update" then
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local fh = io.open(PAC .. "/data/status.json", "w")
    if fh then
        fh:write('{"state":"running","message":"已触发更新，正在准备…","updated":"'
                 .. now .. '"}\n')
        fh:close()
    end
    os.execute("cd " .. PAC .. " && nohup " .. PY .. " " .. TOOLS
               .. " update >> work/update.log 2>&1 &")
    reply('{"ok":true,"state":"running"}')
    return
end

reply('{"ok":false,"error":"未知操作"}', ngx.HTTP_BAD_REQUEST)
