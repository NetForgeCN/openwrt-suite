'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('singbox_core', _('节点'),
			_('当前只支持单节点。保存后会先做配置校验，校验不通过则保留原配置，不会断网。'));

		/* ---------- 服务开关 ---------- */

		s = m.section(form.NamedSection, 'main', 'singbox_core', _('服务'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用'),
			_('关闭时只停止服务、不接管流量，配置保留。填完下面的节点后保存即可生效。'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('日志级别'));
		o.value('error', _('错误'));
		o.value('warn', _('警告'));
		o.value('info', _('信息'));
		o.value('debug', _('调试'));
		o.default = 'info';

		/* ---------- 节点 ---------- */

		s = m.section(form.NamedSection, 'node', 'node', _('上游节点'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.ListValue, 'protocol', _('协议'));
		o.value('hysteria2', 'Hysteria2');
		o.value('tuic', 'TUIC');
		o.default = 'hysteria2';
		o.rmempty = false;

		o = s.option(form.Value, 'server', _('服务器地址'));
		o.datatype = 'host';
		o.placeholder = 'example.com';
		o.rmempty = false;

		o = s.option(form.Value, 'server_port', _('端口'));
		o.datatype = 'port';
		o.default = '443';
		o.rmempty = false;

		o = s.option(form.Value, 'password', _('密码'));
		o.password = true;
		o.rmempty = true;

		o = s.option(form.Value, 'sni', _('TLS SNI'));
		o.placeholder = _('留空则使用服务器地址');
		o.rmempty = true;

		o = s.option(form.Flag, 'insecure', _('跳过证书校验'),
			_('仅当服务端使用自签证书时开启'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'obfs', _('混淆'),
			_('Hysteria2 的 Salamander 混淆，服务端未开启则留空'));
		o.value('', _('不启用'));
		o.value('salamander', 'Salamander');
		o.default = '';
		o.depends('protocol', 'hysteria2');

		o = s.option(form.Value, 'obfs_password', _('混淆密码'));
		o.password = true;
		o.depends('obfs', 'salamander');
		o.rmempty = true;

		o = s.option(form.Value, 'uuid', _('UUID'),
			_('TUIC 使用 UUID + 密码认证'));
		o.depends('protocol', 'tuic');
		o.rmempty = true;
		// LuCI 没有内置 uuid 数据类型，自己校验，否则非法值会一路写进配置
		o.validate = function(section_id, value) {
			if (value == null || value === '')
				return true;
			if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))
				return _('UUID 格式不正确，应为 8-4-4-4-12 的十六进制');
			return true;
		};

		o = s.option(form.ListValue, 'congestion_control', _('拥塞控制'));
		o.value('bbr', 'BBR');
		o.value('cubic', 'CUBIC');
		o.value('new_reno', 'NewReno');
		o.default = 'bbr';
		o.depends('protocol', 'tuic');

		o = s.option(form.ListValue, 'udp_relay_mode', _('UDP 转发模式'));
		o.value('native', _('原生'));
		o.value('quic', 'QUIC');
		o.default = 'native';
		o.depends('protocol', 'tuic');

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
