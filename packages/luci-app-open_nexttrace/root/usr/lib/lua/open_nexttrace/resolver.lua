-- SPDX-License-Identifier: GPL-3.0-only
-- Small UDP DNS client used when the user selects an interface supplied or
-- custom resolver. Binding the socket to an address from the selected OpenWrt
-- interface lets source based multi-WAN policy choose the intended uplink.
local M = {}

local function u16(value)
    return string.char(math.floor(value / 256) % 256, value % 256)
end

local function read16(data, offset)
    local a, b = data:byte(offset, offset + 1)
    if not b then return nil end
    return a * 256 + b
end

local function encode_name(name)
    local labels = {}
    for label in name:gmatch("[^.]+") do
        if #label == 0 or #label > 63 then error("域名标签长度无效", 0) end
        labels[#labels + 1] = string.char(#label) .. label
    end
    if #labels == 0 then error("域名无效", 0) end
    return table.concat(labels) .. "\0"
end

local function skip_name(data, offset)
    local seen = 0
    while true do
        local length = data:byte(offset)
        if not length then return nil end
        if length >= 192 then
            if not data:byte(offset + 1) then return nil end
            return offset + 2
        end
        if length == 0 then return offset + 1 end
        if length > 63 or offset + length > #data then return nil end
        offset = offset + length + 1
        seen = seen + 1
        if seen > 127 then return nil end
    end
end

local function ipv6(data, offset)
    local groups = {}
    for i = 0, 14, 2 do
        groups[#groups + 1] = string.format("%x", assert(read16(data, offset + i)))
    end
    return table.concat(groups, ":")
end

local function parse(data, id, qtype)
    if type(data) ~= "string" or #data < 12 or read16(data, 1) ~= id then
        return nil, "DNS 返回了无效响应"
    end
    local flags, questions, answers = read16(data, 3), read16(data, 5), read16(data, 7)
    if not flags or flags % 16 ~= 0 then return nil, "DNS 服务器返回错误" end
    local offset = 13
    for _ = 1, questions do
        offset = skip_name(data, offset)
        if not offset or offset + 3 > #data then return nil, "DNS 问题段损坏" end
        offset = offset + 4
    end
    local addresses, seen = {}, {}
    for _ = 1, answers do
        offset = skip_name(data, offset)
        if not offset or offset + 9 > #data then return nil, "DNS 应答段损坏" end
        local rtype, class, length = read16(data, offset), read16(data, offset + 2), read16(data, offset + 8)
        offset = offset + 10
        if not length or offset + length - 1 > #data then return nil, "DNS 记录长度无效" end
        if class == 1 and rtype == qtype then
            local address
            if qtype == 1 and length == 4 then
                address = table.concat({data:byte(offset, offset + 3)}, ".")
            elseif qtype == 28 and length == 16 then
                address = ipv6(data, offset)
            end
            if address and not seen[address] then
                addresses[#addresses + 1], seen[address] = address, true
            end
        end
        offset = offset + length
    end
    if #addresses > 0 then return addresses end
    return nil, qtype == 28 and "域名没有 AAAA 记录" or "域名没有 A 记录"
end

local function query(nixio, target, qtype, server, port, source, timeout)
    local random = nixio.open("/dev/urandom", "r")
    local bytes = random and random:read(2) or nil
    if random then random:close() end
    local id = bytes and read16(bytes, 1) or
        (math.floor(nixio.sysinfo().uptime * 1000) + #target * 257 + qtype) % 65536
    local packet = u16(id) .. u16(0x0100) .. u16(1) .. u16(0) .. u16(0) .. u16(0) ..
        encode_name(target) .. u16(qtype) .. u16(1)
    local family = server:find(":", 1, true) and "inet6" or "inet"
    local socket = assert(nixio.socket(family, "dgram"), "无法创建 DNS 套接字")
    local ok, result, message = pcall(function()
        if source and source ~= "" then assert(socket:bind(source, 0), "无法绑定 DNS 来源地址") end
        assert(socket:connect(server, port), "无法连接 DNS 服务器")
        assert(socket:setblocking(false), "无法设置 DNS 套接字")
        local sent = socket:send(packet)
        if sent ~= #packet then error("无法发送 DNS 请求", 0) end
        local fds = {{ fd = socket, events = nixio.poll_flags("in", "err", "hup") }}
        local ready = nixio.poll(fds, timeout)
        if not ready or ready == 0 then error("DNS 查询超时", 0) end
        local response = socket:recv(4096)
        if not response then error("无法读取 DNS 响应", 0) end
        local address, problem = parse(response, id, qtype)
        if not address then error(problem, 0) end
        return address
    end)
    socket:close()
    if not ok then return nil, tostring(result) end
    return result, message
end

function M.resolve_all(nixio, options)
    local types = options.family == "6" and {28} or (options.family == "4" and {1} or {1, 28})
    local addresses, seen, last_error = {}, {}, nil
    for _, qtype in ipairs(types) do
        local found, problem = query(nixio, options.target, qtype, options.server,
            options.port or 53, options.source, options.timeout or 5000)
        for _, address in ipairs(found or {}) do
            if not seen[address] then addresses[#addresses + 1], seen[address] = address, true end
        end
        last_error = problem
    end
    if #addresses > 0 then return addresses end
    error("自定义 DNS 解析失败：" .. (last_error or "没有可用地址"), 0)
end

function M.resolve(nixio, options)
    return M.resolve_all(nixio, options)[1]
end

-- Exposed for deterministic protocol tests; runtime callers use resolve().
M._parse = parse
M._u16 = u16

return M
