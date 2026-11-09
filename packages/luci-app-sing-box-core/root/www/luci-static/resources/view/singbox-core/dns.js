'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('singbox_core', _('DNS'),
			_('国内域名走阿里 DoH，其余走 Google DoH。两个上游都是加密查询，明文 DNS 只用作 bootstrap。'));

		s = m.section(form.NamedSection, 'dns', 'dns', _('DNS 设置'));
		s.anonymous = true;
		s.addremove = false;

		s.tab('upstream', _('加密上游'));
		s.tab('split', _('分流'));
		s.tab('cache', _('缓存'));

		/* ---------- 加密上游 ---------- */

		o = s.taboption('upstream', form.Value, 'bootstrap', _('Bootstrap DNS'),
			_('明文 UDP，仅用于解析 DoH 服务器自身的域名。必须是不经过代理就能访问的地址。'));
		o.datatype = 'ip4addr';
		o.default = '223.5.5.5';
		o.rmempty = false;

		o = s.taboption('upstream', form.Value, 'cn_server', _('国内 DoH 地址'),
			_('填 IP（如 223.5.5.5）会直接连，不需要 bootstrap；填域名则需要。'));
		o.datatype = 'host';
		o.default = '223.5.5.5';
		o.rmempty = false;

		o = s.taboption('upstream', form.Value, 'cn_path', _('国内 DoH 路径'));
		o.default = '/dns-query';
		o.rmempty = false;

		o = s.taboption('upstream', form.Value, 'remote_server', _('国外 DoH 地址'),
			_('走代理出站。域名形式会自动用 bootstrap 解析，IP 形式则省一跳。'));
		o.datatype = 'host';
		o.default = 'dns.google';
		o.rmempty = false;

		o = s.taboption('upstream', form.Value, 'remote_path', _('国外 DoH 路径'));
		o.default = '/dns-query';
		o.rmempty = false;

		/* ---------- 分流 ---------- */

		o = s.taboption('split', form.DynamicList, 'remote_categories', _('强制走国外的分类'),
			_('geosite 分类名，不加 geosite: 前缀。这些分类即使命中 geosite-cn 也走国外解析。'));
		o.placeholder = 'google';

		o = s.taboption('split', form.ListValue, 'strategy', _('解析策略'));
		o.value('prefer_ipv4', _('优先 IPv4'));
		o.value('prefer_ipv6', _('优先 IPv6'));
		o.value('ipv4_only', _('仅 IPv4'));
		o.value('ipv6_only', _('仅 IPv6'));
		o.default = 'prefer_ipv4';

		/* ---------- 缓存 ---------- */

		o = s.taboption('cache', form.Value, 'cache_capacity', _('缓存条数'),
			_('小于 1024 的值会被 sing-box 静默忽略，这里会自动纠正为 4096。'));
		o.datatype = 'uinteger';
		o.default = '4096';
		o.rmempty = false;

		o = s.taboption('cache', form.Flag, 'optimistic', _('乐观缓存'),
			_('条目过期后先返回旧结果并在后台刷新，减少等待。需要 sing-box 1.14 及以上，低版本会自动跳过。'));
		o.default = '1';
		o.rmempty = false;

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
