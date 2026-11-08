'use strict';
'require view';
'require form';
'require rpc';

var info = rpc.declare({ object: 'open_nexttrace', method: 'info', expect: { '': {} } });

return view.extend({
    load: function() {
        return info();
    },

    render: function(data) {
        var m = new form.Map('open_nexttrace', 'Open NextTrace 设置',
            '跳数、探测次数、超时、端口和 rDNS 始终以本页为准；追踪页可临时选择协议、地址类型、DNS、IP 解析 API 和 WAN 口。');
        var s = m.section(form.NamedSection, 'main', 'open_nexttrace', '默认追踪参数');
        s.anonymous = true;
        s.addremove = false;

        var o = s.option(form.ListValue, 'protocol', '协议');
        o.value('icmp', 'ICMP'); o.value('tcp', 'TCP'); o.value('udp', 'UDP'); o.default = 'icmp';
        o = s.option(form.ListValue, 'family', '地址类型');
        o.value('auto', '自动'); o.value('4', 'IPv4'); o.value('6', 'IPv6'); o.default = 'auto';
        o = s.option(form.ListValue, 'device', '默认追踪出口');
        o.value('', '默认出口（系统路由）');
        (data.interfaces || []).forEach(function(iface) {
            if (!iface.up) return;
            o.value(iface.device, (iface.name || iface.device) + ' · ' + iface.device + (iface.wan ? ' · WAN' : ''));
        });
        o = s.option(form.ListValue, 'provider', 'IP 数据源');
        o.value('NextTrace-API', 'NextTrace');
        o.value('IPInfo', 'IPInfo');
        o.value('IP.SB', 'IP.SB');
        o.value('IPAPI.com', 'IP-API.com');
        o.value('disable-geoip', '禁用');
        o.default = 'NextTrace-API';
        o = s.option(form.Value, 'max_hops', '最大跳数');
        o.datatype = 'range(1,64)'; o.default = '30';
        o = s.option(form.Value, 'queries', '每跳探测次数');
        o.datatype = 'range(1,5)'; o.default = '3';
        o = s.option(form.Value, 'timeout', '探测超时 (ms)');
        o.datatype = 'range(100,5000)'; o.default = '1000';
        o = s.option(form.Value, 'tcp_port', 'TCP 目标端口');
        o.datatype = 'port'; o.default = '80';
        o = s.option(form.Value, 'udp_port', 'UDP 目标端口');
        o.datatype = 'port'; o.default = '33494';
        o = s.option(form.Flag, 'rdns', '反向 DNS 查询');
        o.default = o.enabled;

        s = m.section(form.NamedSection, 'main', 'open_nexttrace', '域名解析');
        s.anonymous = true;
        s.addremove = false;
        s.description = '系统默认模式由 NextTrace 使用路由器解析器。接口 DNS 和自定义 DNS 模式会先解析目标，并可绑定所选接口的源地址，适用于多 WAN。';
        o = s.option(form.ListValue, 'dns_mode', 'DNS 模式');
        o.value('system', '系统默认');
        o.value('interface', '使用接口下发的 DNS');
        o.value('custom', '自定义 DNS');
        o.default = 'system';
        o = s.option(form.ListValue, 'dns_interface', 'DNS 来源接口');
        o.value('', '默认出口（不绑定源地址）');
        (data.interfaces || []).forEach(function(iface) {
            if (!iface.up) return;
            var dns = (iface.dns || []).join(', ');
            o.value(iface.name, (iface.name || iface.device) + ' · ' + iface.device + (dns ? ' · ' + dns : ' · 无 DNS'));
        });
        o.depends('dns_mode', 'interface');
        o.depends('dns_mode', 'custom');
        o = s.option(form.Value, 'dns_server', '自定义 DNS 服务器');
        o.datatype = 'ipaddr';
        o.placeholder = '223.5.5.5';
        o.rmempty = false;
        o.depends('dns_mode', 'custom');
        o = s.option(form.Value, 'dns_port', 'DNS 端口');
        o.datatype = 'port';
        o.default = '53';
        o.depends('dns_mode', 'interface');
        o.depends('dns_mode', 'custom');

        return m.render();
    }
});
