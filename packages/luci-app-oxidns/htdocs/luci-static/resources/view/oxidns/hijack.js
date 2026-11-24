'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

/*
 * DNS 劫持独立页（2026-11 从 overview.js 拆出）。
 *
 * 把局域网发往 53 端口的 DNS 请求（TCP/UDP、IPv4/IPv6）重定向到本机
 * OxiDNS 监听端口。目标端口可自动读 config.yaml 或手工指定，实现为 fw4
 * firewall redirect，路由器自身的查询不受影响。
 */

var callHijackGet = rpc.declare({
	object: 'luci.oxidns',
	method: 'hijack_get',
	expect: {}
});

var callHijackSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'hijack_save',
	params: [ 'enabled', 'port_mode', 'port' ],
	expect: {}
});

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
	expect: {}
});

var hijackState = {};
var statusState = {};

function valueOrDash(value) {
	if (value === null || value === undefined || value === '')
		return '-';
	return value;
}

function setNodeContent(node, value) {
	while (node.firstChild)
		node.removeChild(node.firstChild);

	if (value && value.nodeType)
		node.appendChild(value);
	else
		node.textContent = valueOrDash(value);
}

function renderRow(label, value, id) {
	var attrs = { 'class': 'td left' };
	if (id)
		attrs.id = id;

	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', attrs, valueOrDash(value))
	]);
}

function statusBadge(text, good) {
	return E('span', {
		'class': good ? 'label label-success' : 'label label-warning'
	}, text);
}

function hijackStatusBadge(hijack) {
	return hijack && hijack.enabled ? statusBadge(_('Enabled'), true) : statusBadge(_('Disabled'), false);
}

function coreInstalled(status) {
	return !!(status && status.core && status.core.installed);
}

function hijackPortText(hijack) {
	var source = (hijack && hijack.port_mode === 'manual')
		? _('manual')
		: _('from config.yaml');

	if (!hijack || (hijack.udp_port == null && hijack.tcp_port == null))
		return _('No target port available (source: %s).').format(source);

	var ports;
	if (hijack.udp_port != null && hijack.udp_port === hijack.tcp_port)
		ports = _('port %s (TCP/UDP)').format(hijack.udp_port);
	else
		ports = _('UDP port %s, TCP port %s')
			.format(hijack.udp_port == null ? '-' : hijack.udp_port,
				hijack.tcp_port == null ? '-' : hijack.tcp_port);

	return _('%s, %s').format(source, ports);
}

function hijackSelectedMode() {
	var box = document.querySelector('input[name="oxidns-hijack-port-mode"]:checked');
	return (box && box.value === 'manual') ? 'manual' : 'auto';
}

function hijackPortInput() {
	return document.getElementById('oxidns-hijack-port');
}

// auto 时手填框禁用并置灰；manual 时才允许输入
function syncHijackPortInput() {
	var input = hijackPortInput();
	if (!input)
		return;
	input.disabled = (hijackSelectedMode() !== 'manual');
}

function setHijackStatus(message, danger) {
	var node = document.getElementById('oxidns-hijack-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

// 每次轮询都按后端状态重绘：勾选框、端口来源、目标端口，以及「当前生效的规则段」
// 列表都以 hijack_get 的结果为准，避免界面与实际防火墙状态漂移。
// 代价是 5 秒一次覆盖输入框 —— 所以只在用户没聚焦时回填，否则会把他敲的字冲掉。
function applyHijackState(hijack) {
	hijack = hijack || {};

	var box = document.getElementById('oxidns-hijack-enabled');
	if (box)
		box.checked = !!hijack.enabled;

	var mode = (hijack.port_mode === 'manual') ? 'manual' : 'auto';
	var autoBox = document.getElementById('oxidns-hijack-mode-auto');
	var manualBox = document.getElementById('oxidns-hijack-mode-manual');
	if (autoBox)
		autoBox.checked = (mode === 'auto');
	if (manualBox)
		manualBox.checked = (mode === 'manual');

	var input = hijackPortInput();
	if (input) {
		if (document.activeElement !== input) {
			var value = hijack.manual_port;
			if (value == null && hijack.udp_port != null)
				value = hijack.udp_port;
			input.value = (value == null) ? '' : String(value);
		}
		input.disabled = (mode !== 'manual');
	}

	setNodeContent(document.getElementById('oxidns-hijack-ports'), hijackPortText(hijack));
	setNodeContent(document.getElementById('oxidns-hijack-sections'), (hijack.sections || []).join(', '));
}

function refreshHijack() {
	return L.resolveDefault(callHijackGet(), {}).then(function(hijack) {
		hijackState = hijack || {};
		applyHijackState(hijackState);
		return hijackState;
	});
}

function refreshStatus() {
	return L.resolveDefault(callStatus(), {}).then(function(status) {
		statusState = status || {};
		updateHijackControls();
	});
}

function refreshAll() {
	return Promise.all([ refreshStatus(), refreshHijack() ]);
}

function updateHijackControls() {
	var node = document.getElementById('oxidns-hijack-core-hint');
	if (!node)
		return;

	if (coreInstalled(statusState)) {
		node.style.display = 'none';
		return;
	}

	node.style.display = 'block';
	node.textContent = _('Install the OxiDNS core before DNS hijack can redirect to a local listener.');
}

function saveHijack() {
	var box = document.getElementById('oxidns-hijack-enabled');
	var enabled = !!(box && box.checked);
	var mode = hijackSelectedMode();
	var input = hijackPortInput();
	var port = input ? String(input.value || '').trim() : '';

	// 设置本身要合法：manual 下端口必须是 1-65535。后端同样会校验，这里先挡一次。
	if (mode === 'manual') {
		var portNumber = parseInt(port, 10);
		if (!/^[0-9]+$/.test(port) || portNumber < 1 || portNumber > 65535) {
			setHijackStatus(_('Enter a port number between 1 and 65535.'), true);
			return Promise.resolve();
		}
		port = String(portNumber);
	}

	ui.showModal(_('OxiDNS'), [
		E('p', {}, _('Applying DNS hijack...'))
	]);

	return L.resolveDefault(callHijackSave(enabled, mode, port), null).then(function(result) {
		ui.hideModal();
		if (result && result.ok !== false)
			applyHijackState(result);

		if (!result || result.ok === false) {
			setHijackStatus((result && (result.message || result.error)) || _('Failed to apply DNS hijack'), true);
			return refreshHijack();
		}
		if (result.warn === 'firewall_reload_failed') {
			setHijackStatus(_('Rules were written, but the firewall reload failed. The rules take effect on the next firewall reload or reboot.'), true);
			return;
		}
		setHijackStatus(result.enabled
			? _('DNS hijack enabled. LAN port 53 requests are redirected to OxiDNS.')
			: _('DNS hijack disabled.'), false);
	}).catch(function(err) {
		ui.hideModal();
		setHijackStatus(err.message || String(err), true);
		return refreshHijack();
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callHijackGet(), {}),
			L.resolveDefault(callStatus(), {})
		]).then(function(results) {
			return {
				hijack: results[0] || {},
				status: results[1] || {}
			};
		});
	},

	render: function(data) {
		var hijack = (data && data.hijack) || {};
		var status = (data && data.status) || {};

		hijackState = hijack;
		statusState = status;
		poll.add(refreshAll, 5);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('DNS Hijack')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Redirect LAN DNS requests on port 53 (TCP and UDP, IPv4 and IPv6) to the local OxiDNS DNS listener.')),
			E('div', { 'class': 'cbi-section', 'id': 'oxidns-hijack-section' }, [
				E('div', {
					'id': 'oxidns-hijack-core-hint',
					'class': 'alert-message warning',
					'style': 'margin: 1em 0; display: none;'
				}),
				E('div', { 'class': 'table cbi-section-table' }, [
					renderRow(_('Status'), hijackStatusBadge(hijack)),
					renderRow(_('Target ports'), '-', 'oxidns-hijack-ports'),
					renderRow(_('Active firewall sections'), '-', 'oxidns-hijack-sections')
				]),
				E('div', { 'style': 'margin: .75em 0;' }, [
					E('label', { 'style': 'display: block; margin-bottom: .35em;' }, [
						E('input', {
							'id': 'oxidns-hijack-mode-auto',
							'type': 'radio',
							'name': 'oxidns-hijack-port-mode',
							'value': 'auto',
							'checked': (hijack.port_mode === 'manual') ? null : 'checked',
							'style': 'margin-right: .5em;',
							'change': function() { syncHijackPortInput(); }
						}),
						_('Read the port from config.yaml automatically')
					]),
					E('label', { 'style': 'display: block;' }, [
						E('input', {
							'id': 'oxidns-hijack-mode-manual',
							'type': 'radio',
							'name': 'oxidns-hijack-port-mode',
							'value': 'manual',
							'checked': (hijack.port_mode === 'manual') ? 'checked' : null,
							'style': 'margin-right: .5em;',
							'change': function() { syncHijackPortInput(); }
						}),
						_('Use a manual port'),
						' ',
						E('input', {
							'id': 'oxidns-hijack-port',
							'type': 'text',
							'inputmode': 'numeric',
							'placeholder': '5353',
							'value': (hijack.manual_port != null) ? String(hijack.manual_port) : '',
							'disabled': (hijack.port_mode === 'manual') ? null : 'disabled',
							'style': 'width: 6em; margin-left: .4em;'
						})
					])
				]),
				E('label', { 'style': 'display: block; margin: .5em 0;' }, [
					E('input', {
						'id': 'oxidns-hijack-enabled',
						'type': 'checkbox',
						'checked': hijack.enabled ? 'checked' : null,
						'style': 'margin-right: .5em;'
					}),
					_('Enable DNS hijack')
				]),
				E('div', { 'class': 'cbi-button-row' }, [
					E('button', {
						'id': 'oxidns-hijack-apply',
						'class': 'btn cbi-button cbi-button-positive',
						'click': function(ev) {
							ev.preventDefault();
							return saveHijack();
						}
					}, _('Apply'))
				]),
				E('div', { 'id': 'oxidns-hijack-status', 'style': 'margin-top: 1em;' })
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
