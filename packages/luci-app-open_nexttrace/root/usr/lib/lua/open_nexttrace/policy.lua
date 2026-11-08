-- SPDX-License-Identifier: GPL-3.0-only
-- Pure validation / argv construction. No user input is ever a shell command.
local M = {}

local function ipv4(value)
    if type(value) ~= "string" then return false end
    local count = 0
    for part in value:gmatch("[^.]+") do
        if not part:match("^%d+$") or tonumber(part) > 255 then return false end
        count = count + 1
    end
    return count == 4 and not value:match("^%.") and not value:match("%.$")
end

local function ipv6(value)
    return type(value) == "string" and #value <= 45 and value:find(":", 1, true) ~= nil and
        value:match("^[0-9a-fA-F:]+$") ~= nil
end

local function integer(value, default, lo, hi, name)
    if value == nil then value = default end
    if type(value) ~= "number" or value ~= math.floor(value) or value < lo or value > hi then
        error(name .. " 参数超出允许范围", 0)
    end
    return value
end

function M.interfaces(dump)
    local result = {}
    for _, item in ipairs(dump.interface or {}) do
        local device = item.l3_device or item.device
        if type(device) == "string" and device ~= "lo" and device:match("^[%w_.:@%-]+$") then
            local addresses, families, dns = {}, {}, {}
            for _, addr in ipairs(item["ipv4-address"] or {}) do
                addresses[#addresses + 1] = addr.address
                families.v4 = true
            end
            for _, addr in ipairs(item["ipv6-address"] or {}) do
                addresses[#addresses + 1] = addr.address
                families.v6 = true
            end
            for _, server in ipairs(item["dns-server"] or {}) do
                if ipv4(server) or ipv6(server) then dns[#dns + 1] = server end
            end
            local wan = false
            for _, route in ipairs(item.route or {}) do
                if tonumber(route.mask) == 0 then wan = true end
            end
            result[#result + 1] = {
                name = item.interface, device = device, up = item.up == true,
                wan = wan, addresses = addresses, dns = dns, ipv4 = families.v4 == true,
                ipv6 = families.v6 == true
            }
        end
    end
    table.sort(result, function(a, b)
        if a.wan ~= b.wan then return a.wan end
        return (a.name or "") < (b.name or "")
    end)
    return result
end

function M.target(target)
    if type(target) ~= "string" or #target == 0 or #target > 253 or
        not target:match("^[%w:][%w.:%-]*$") or target:find("_", 1, true) then
        error("请输入有效的域名、IPv4 或 IPv6 地址（不含 URL、空格或命令参数）", 0)
    end
    return ipv4(target) or ipv6(target)
end

function M.build(input, interfaces, explicit_traceroute)
    local target = input.target
    M.target(target)
    local protocol = input.protocol or "icmp"
    local family = input.family or "auto"
    local device = input.device or ""
    if protocol ~= "icmp" and protocol ~= "tcp" and protocol ~= "udp" then
        error("不支持的探测协议", 0)
    end
    if family ~= "auto" and family ~= "4" and family ~= "6" then
        error("不支持的地址类型", 0)
    end
    if type(device) ~= "string" then error("无效的出口接口", 0) end
    if device ~= "" then
        local found = false
        for _, iface in ipairs(interfaces) do
            if iface.device == device and iface.up and
                (family == "auto" or (family == "4" and iface.ipv4) or (family == "6" and iface.ipv6)) then
                found = true
            end
        end
        if not found then error("出口接口已离线、不存在或不支持所选地址类型，请刷新接口", 0) end
    end
    local hops = integer(input.max_hops, 30, 1, 64, "最大跳数")
    local queries = integer(input.queries, 3, 1, 5, "每跳探测次数")
    local timeout = integer(input.timeout, 1000, 100, 5000, "超时")
    local port = integer(input.port, protocol == "udp" and 33494 or 80, 1, 65535, "端口")
    local provider = input.provider or "NextTrace-API"
    if provider ~= "NextTrace-API" and provider ~= "IP.SB" and provider ~= "IPInfo" and
        provider ~= "IPAPI.com" and provider ~= "disable-geoip" then
        error("不支持的 IP 数据源", 0)
    end
    if input.rdns ~= nil and type(input.rdns) ~= "boolean" then error("无效的 rDNS 设置", 0) end
    local argv = { "--raw", "--map", "--no-color", "--language", "cn",
        "--max-hops", tostring(hops), "--queries", tostring(queries),
        "--timeout", tostring(timeout), "--data-provider", provider }
    -- v1.7.3 defaults to traditional trace but does not know --traceroute.
    -- Newer cores expose it, and may eventually change the default mode.
    if explicit_traceroute then table.insert(argv, 1, "--traceroute") end
    if protocol == "tcp" then argv[#argv + 1] = "--tcp" end
    if protocol == "udp" then argv[#argv + 1] = "--udp" end
    if protocol ~= "icmp" then
        argv[#argv + 1] = "--port"
        argv[#argv + 1] = tostring(port)
    end
    if family ~= "auto" then argv[#argv + 1] = "-" .. family end
    if device ~= "" then
        argv[#argv + 1] = "--dev"
        argv[#argv + 1] = device
    end
    if input.rdns == false then argv[#argv + 1] = "--no-rdns" end
    argv[#argv + 1] = target
    return argv
end

function M.resolver(input, interfaces)
    local server = input.dns_server
    if server == nil or server == "" or ipv4(input.target) or ipv6(input.target) then return nil end
    if not ipv4(server) and not ipv6(server) then error("自定义 DNS 服务器必须是 IPv4 或 IPv6 地址", 0) end
    local source = input.dns_source or ""
    if type(source) ~= "string" then error("无效的 DNS 来源地址", 0) end
    if source ~= "" then
        local found = false
        for _, iface in ipairs(interfaces) do
            if iface.up then
                for _, address in ipairs(iface.addresses or {}) do
                    if address == source then found = true end
                end
            end
        end
        if not found then error("DNS 来源接口已离线或地址已变化，请刷新设置", 0) end
        if ipv4(server) ~= ipv4(source) then error("DNS 服务器与来源接口地址类型不一致", 0) end
    end
    return {
        target = input.target, family = input.family or "auto", server = server,
        source = source, port = integer(input.dns_port, 53, 1, 65535, "DNS 端口"), timeout = 5000
    }
end

return M
