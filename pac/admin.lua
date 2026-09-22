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
    -- 检查锁文件：如果存在且未过期（30 分钟），说明有更新在进行
    local LOCK = PAC .. "/data/update.lock"
    local STALE_SECONDS = 1800 -- 30 分钟
    local function lock_stale()
        local f = io.open(LOCK, "r")
        if not f then return false end
        local pid = f:read("*l")
        f:close()
        -- 锁文件存在即视为占用中，由 tools.py 自己管理清理
        return true
    end

    if lock_stale() then
        -- 尝试检查进程是否还活着
        local f = io.open(LOCK, "r")
        local pid = f and f:read("*l") or nil
        if f then f:close() end
        if pid then
            local check = io.popen("kill -0 " .. pid .. " 2>/dev/null && echo alive || echo dead")
            local alive = check:read("*a")
            check:close()
            if alive:match("alive") then
                reply('{"ok":false,"error":"已有更新任务在进行中（PID " .. pid .. "）"}', 409)
                return
            else
                -- 进程已死，清理过期锁
                os.remove(LOCK)
            end
        end
    end

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

-- 取消/重置卡住的更新任务
if action == "abort" then
    local LOCK = PAC .. "/data/update.lock"
    local fh = io.open(LOCK, "r")
    local pid = nil
    if fh then
        pid = fh:read("*l")
        fh:close()
    end
    if pid then
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    os.remove(LOCK)
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local sfh = io.open(PAC .. "/data/status.json", "w")
    if sfh then
        sfh:write('{"state":"idle","message":"已手动取消更新","updated":"' .. now .. '"}\n')
        sfh:close()
    end
    reply('{"ok":true,"state":"idle","message":"已取消"}')
    return
end

-- 添加海外代理域名
if action == "add-proxy-domain" then
    local domain = arg("domain")
    if not domain or domain == "" then
        reply('{"ok":false,"error":"域名不能为空"}', ngx.HTTP_BAD_REQUEST)
        return
    end
    domain = domain:lower():match("^%s*(.-)%s*$")
    if domain == "" or #domain > 253 or domain:match("[^a-z0-9%.%-]") then
        reply('{"ok":false,"error":"域名格式不合法"}', ngx.HTTP_BAD_REQUEST)
        return
    end

    -- 检查是否已在 cn-domains.txt（国内直连）中
    local CN_FILE = PAC .. "/data/cn-domains.txt"
    local cf = io.open(CN_FILE, "r")
    local found = false
    if cf then
        for line in cf:lines() do
            if line:match("^%s*(.-)%s*$") == domain then
                found = true
                break
            end
        end
        cf:close()
    end
    if found then
        reply('{"ok":false,"error":"该域名已在直连名单中，无需添加到代理名单"}', ngx.HTTP_BAD_REQUEST)
        return
    end

    -- 检查是否已在 proxy-list.txt 中
    local PF = PAC .. "/data/proxy-list.txt"
    local pf = io.open(PF, "a")
    if not pf then
        reply('{"ok":false,"error":"无法写入 proxy-list.txt"}', ngx.HTTP_INTERNAL_SERVER_ERROR)
        return
    end
    -- 先读取去重
    local existing = {}
    local rf = io.open(PF, "r")
    if rf then
        for line in rf:lines() do
            local s = line:match("^%s*(.-)%s*$")
            if s and s ~= "" and not s:match("^#") then
                existing[s] = true
            end
        end
        rf:close()
    end
    if existing[domain] then
        pf:close()
        reply('{"ok":true,"message":"域名已存在","domain":"' .. domain .. '"}')
        return
    end
    -- 确保文件末尾有换行再追加
    local eof_check = io.open(PF, "r")
    local needs_newline = true
    if eof_check then
        local content = eof_check:read("*a")
        if content ~= "" and content:sub(-1) == "\n" then needs_newline = false end
        eof_check:close()
    end
    pf:seek("end")
    if needs_newline then pf:write("\n") end
    pf:write(domain .. "\n")
    pf:close()

    -- 重新渲染 PAC
    os.execute("cd " .. PAC .. " && nohup " .. PY .. " " .. TOOLS
               .. " render >> work/render.log 2>&1 &")

    reply('{"ok":true,"message":"已添加到代理名单","domain":"' .. domain .. '"}')
    return
end
if action == "list" then
    -- 前端用 POST 表单提交，offset/limit 可能只出现在请求体里
    local offset = tonumber(arg("offset") or "0") or 0
    local limit  = tonumber(arg("limit")  or "50") or 50
    if offset < 0 then offset = 0 end
    if limit < 1 then limit = 1 end
    if limit > 20000 then limit = 20000 end
    local DOMAIN_FILE = PAC .. "/data/cn-domains.txt"
    local EXTRA_FILE  = PAC .. "/data/extra-domains.txt"
    local f = io.open(DOMAIN_FILE, "r")
    local all = {}
    if f then
        for line in f:lines() do
            local s = line:match("^%s*(.-)%s*$")
            if s and s ~= "" then all[#all + 1] = s end
        end
        f:close()
    end
    local ef = io.open(EXTRA_FILE, "r")
    if ef then
        for line in ef:lines() do
            local s = line:match("^%s*(.-)%s*$")
            if s and s ~= "" then all[#all + 1] = s end
        end
        ef:close()
    end
    local total = #all
    local slice = {}
    for i = offset + 1, math.min(offset + limit, total) do
        slice[#slice + 1] = all[i]
    end
    -- 简单统计：TLD 分布
    local tlds = {}
    for _, d in ipairs(all) do
        local tld = d:match("%.([a-z0-9]+)$") or "(other)"
        tlds[tld] = (tlds[tld] or 0) + 1
    end
    -- 按数量排序，取前 15
    local tld_list = {}
    for t, c in pairs(tlds) do tld_list[#tld_list + 1] = {tld = t, count = c} end
    table.sort(tld_list, function(a, b) return a.count > b.count end)
    local top_tlds = {}
    for i = 1, math.min(15, #tld_list) do top_tlds[#top_tlds + 1] = tld_list[i] end

    -- 手工拼接 JSON（避免依赖 cjson）
    local json_parts = {'{"ok":true,"total":' .. total .. ',"offset":' .. offset .. ',"limit":' .. limit .. ',"domains":['}
    for i, d in ipairs(slice) do
        if i > 1 then json_parts[#json_parts + 1] = ',' end
        json_parts[#json_parts + 1] = '"' .. d:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    end
    json_parts[#json_parts + 1] = '],"top_tlds":['
    for i, t in ipairs(top_tlds) do
        if i > 1 then json_parts[#json_parts + 1] = ',' end
        json_parts[#json_parts + 1] = '{"tld":"' .. t.tld .. '","count":' .. t.count .. '}'
    end
    json_parts[#json_parts + 1] = ']}'
    reply(table.concat(json_parts))
    return
end

reply('{"ok":false,"error":"未知操作"}', ngx.HTTP_BAD_REQUEST)
