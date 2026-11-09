'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('singbox_core', _('分流'),
			_('规则顺序在渲染时固定生成：进程例外 → DNS 劫持 → 强制代理 → 广告拦截 → QUIC 阻断 → 按 MAC → 国内直连 → 私网直连。'));

		s = m.section(form.NamedSection, 'route', 'route', _('分流设置'));
		s.anonymous = true;
		s.addremove = false;

		s.tab('switch', _('总开关'));
		s.tab('tun', _('TUN'));
		s.tab('process', _('进程例外'));
		s.tab('device', _('按设备'));

		/* ---------- 总开关 ---------- */

		o = s.taboption('switch', form.Flag, 'bypass_cn', _('国内流量直连'),
			_('同时作用于 DNS 分流和 IP 分流，两边用同一套 geosite / geoip，避免解析与连接走不同路径。'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('switch', form.Flag, 'block_ads', _('拦截广告域名'),
			_('使用 geosite:category-ads-all。'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('switch', form.Flag, 'block_quic', _('阻断 QUIC（UDP 443）'),
			_('强制应用回落到 TCP，避免 QUIC 绕过分流规则。副作用是部分应用的 UDP 加速会失效。'));
		o.default = '1';
		o.rmempty = false;

		/* ---------- TUN ---------- */

		o = s.taboption('tun', form.Flag, 'auto_redirect', _('启用 auto_redirect'),
			_('在 OpenWrt 上会自动向 fw4 表插入兼容规则，比 TPROXY 性能更好。需要 sing-box 1.10+。'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('tun', form.Value, 'tun_mtu', _('MTU'),
			_('跑 Hysteria2 / TUIC 时不要用默认的 9000，1400 左右更稳。'));
		o.datatype = 'range(576, 9000)';
		o.default = '1400';
		o.rmempty = false;

		o = s.taboption('tun', form.Value, 'tun_address', _('TUN 地址'));
		o.datatype = 'cidr4';
		o.default = '172.19.0.1/30';
		o.rmempty = false;

		o = s.taboption('tun', form.Value, 'tun_table', _('路由表索引'),
			_('与 sing-box 默认的 2022 错开，便于切换时精确清理。'));
		o.datatype = 'uinteger';
		o.default = '2023';
		o.rmempty = false;

		o = s.taboption('tun', form.Value, 'tun_rule', _('ip rule 起始索引'),
			_('与默认的 9000 错开，避免与其他 TUN 应用互相覆盖。'));
		o.datatype = 'uinteger';
		o.default = '9100';
		o.rmempty = false;

		/* ---------- 进程例外 ---------- */

		o = s.taboption('process', form.DynamicList, 'bypass_process', _('必须直连的进程'),
			_('这些进程的所有流量直接走 direct，且排在 DNS 劫持之前，等价于 dae 的 must_direct。'));
		o.placeholder = 'dnsmasq';
		o.datatype = 'string';

		o = s.taboption('process', form.DynamicList, 'dns_hijack_exempt_process', _('不做 DNS 劫持的进程'),
			_('只对 UDP 53 放行，其余流量仍按正常规则分流。'));
		o.placeholder = 'kixdns';
		o.datatype = 'string';

		o = s.taboption('process', form.DynamicList, 'forced_proxy_process', _('强制走代理的进程'),
			_('与下面的目标地址组合生效，仅匹配 443 端口。'));
		o.placeholder = 'hev-socks5-serve';
		o.datatype = 'string';

		o = s.taboption('process', form.DynamicList, 'forced_proxy_target', _('强制代理的目标地址'));
		o.placeholder = '8.8.8.8';
		o.datatype = 'ip4addr';

		/* ---------- 按设备 ---------- */

		o = s.taboption('device', form.Value, 'lan_mac', _('强制走代理的 MAC'),
			_('留空则不启用。需要 sing-box 1.14+ 与邻居解析，同时要配好下面的租约文件。'));
		o.datatype = 'macaddr';
		o.rmempty = true;
		o.placeholder = '00:0c:29:7d:55:cb';

		o = s.taboption('device', form.Value, 'dhcp_lease_file', _('DHCP 租约文件'),
			_('用于把 MAC 和主机名关联起来，OpenWrt 上通常是 /tmp/dhcp.leases。'));
		o.default = '/tmp/dhcp.leases';
		o.depends('lan_mac', '*');

		m.handleSaveApply = function(ev, mode) {
			return form.Map.prototype.handleSaveApply.call(this, ev, mode)
				.then(function() {
					return fs.exec('/usr/libexec/sing-box-core/apply.sh');
				})
				.then(function(res) {
					if (res && res.code !== 0)
						ui.addNotification(null,
							E('pre', { 'style': 'white-space:pre-wrap' },
								res.stderr || _('应用失败')), 'error');
					else
						ui.addNotification(null,
							E('p', _('配置已校验并应用')), 'info');
				});
		};

		return m.render();
	}
});
