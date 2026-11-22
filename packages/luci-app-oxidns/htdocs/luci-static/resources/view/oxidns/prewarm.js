'use strict';
'require view';
'require rpc';
'require ui';

var callPrewarmRead = rpc.declare({
	object: 'luci.oxidns',
	method: 'prewarm_read',
	expect: {}
});

var callPrewarmSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'prewarm_save',
	params: [ 'enabled', 'protocol', 'server', 'port', 'interval', 'content' ],
	expect: {}
});

var callPrewarmRun = rpc.declare({
	object: 'luci.oxidns',
	method: 'prewarm_run',
	expect: {}
});

function field(id) {
	var node = document.getElementById(id);
	return node ? node.value : '';
}

function checked(id) {
	var node = document.getElementById(id);
	return !!(node && node.checked);
}

function row(label, input) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', { 'class': 'td left' }, input)
	]);
}

function option(value, label, selected) {
	return E('option', {
		'value': value,
		'selected': selected ? 'selected' : null
	}, label || value);
}

function select(id, options, value) {
	return E('select', { 'id': id, 'class': 'cbi-input-select' },
		options.map(function(item) {
			return option(item[0], item[1], value === item[0]);
		}));
}

function textInput(id, value) {
	return E('input', {
		'id': id,
		'class': 'cbi-input-text',
		'type': 'text',
		'value': value || ''
	});
}

function listTextarea(content) {
	var value = content || '';
	var textarea = E('textarea', {
		'id': 'oxidns-prewarm-content',
		'class': 'cbi-input-textarea',
		'rows': 20,
		'style': 'width: 100%; box-sizing: border-box; font-family: monospace;',
		'spellcheck': 'false'
	});
	textarea.defaultValue = value;
	textarea.value = value;
	return textarea;
}

function description(id, text) {
	return E('div', {
		'id': id,
		'class': 'cbi-value-description'
	}, text);
}

function setStatus(message, danger) {
	var node = document.getElementById('oxidns-prewarm-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

function callWithTimeout(call, seconds) {
	var previous = L.env.rpctimeout;
	L.env.rpctimeout = seconds;
	return call().then(function(result) {
		if (previous === undefined)
			delete L.env.rpctimeout;
		else
			L.env.rpctimeout = previous;
		return result;
	}, function(err) {
		if (previous === undefined)
			delete L.env.rpctimeout;
		else
			L.env.rpctimeout = previous;
		throw err;
	});
}

function savePrewarm() {
	ui.showModal(_('OxiDNS'), [ E('p', {}, _('Saving prewarm settings...')) ]);
	return L.resolveDefault(callPrewarmSave(
		checked('oxidns-prewarm-enabled') ? '1' : '0',
		field('oxidns-prewarm-protocol') || 'udp',
		field('oxidns-prewarm-server') || '127.0.0.1',
		field('oxidns-prewarm-port') || '5333',
		field('oxidns-prewarm-interval') || '3000',
		field('oxidns-prewarm-content')
	), null).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			setStatus((result && (result.message || result.error)) || _('Failed to save prewarm settings'), true);
			return;
		}
		setStatus(_('Prewarm settings saved.'), false);
	}).catch(function(err) {
		ui.hideModal();
		setStatus(err.message || String(err), true);
	});
}

function runPrewarm() {
	ui.showModal(_('OxiDNS'), [ E('p', {}, _('Warming up...')) ]);
	return L.resolveDefault(callWithTimeout(callPrewarmRun, 180), null).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			setStatus((result && (result.message || result.error)) || _('Prewarm failed'), true);
			return;
		}
		setStatus(_('Prewarm completed.'), false);
	}).catch(function(err) {
		ui.hideModal();
		setStatus(err.message || String(err), true);
	});
}

return view.extend({
	load: function() {
		return L.resolveDefault(callPrewarmRead(), {});
	},

	render: function(settings) {
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Prewarm')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Keep popular domains resolved so the first visit is fast. A and AAAA records are queried through the selected OxiDNS listener.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'table cbi-section-table' }, [
					row(_('Enable prewarming'), E('div', {}, [
						E('input', {
							'id': 'oxidns-prewarm-enabled',
							'type': 'checkbox',
							'checked': settings.enabled !== false ? 'checked' : null
						})
					])),
					row(_('Prewarm list'), E('div', {}, [
						listTextarea(settings.content),
						description('oxidns-prewarm-content-description',
							_('One domain per line. Blank lines and lines starting with # are ignored. Changes apply on the next pass; use Run now to apply immediately.'))
					])),
					row(_('Protocol'), select('oxidns-prewarm-protocol', [
						[ 'udp', _('UDP') ],
						[ 'tcp', _('TCP') ]
					], settings.protocol || 'udp')),
					row(_('Server IP'), select('oxidns-prewarm-server', [
						[ '127.0.0.1', _('127.0.0.1 (local listener)') ],
						[ '192.168.1.1', _('192.168.1.1 (LAN address)') ]
					], settings.server || '127.0.0.1')),
					row(_('Port'), E('div', {}, [
						textInput('oxidns-prewarm-port', settings.port || '5333'),
						description('oxidns-prewarm-port-description',
							_('The selected server must be an OxiDNS listener with cache enabled.'))
					])),
					row(_('Interval (seconds)'), E('div', {}, [
						textInput('oxidns-prewarm-interval', settings.interval || '3000'),
						description('oxidns-prewarm-interval-description',
							_('0 = run once at service start.'))
					]))
				]),
				E('div', { 'class': 'cbi-button-row' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-positive',
						'click': function(ev) {
							ev.preventDefault();
							return savePrewarm();
						}
					}, _('Save Settings')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function(ev) {
							ev.preventDefault();
							return runPrewarm();
						}
					}, _('Run now'))
				]),
				E('div', { 'id': 'oxidns-prewarm-status', 'style': 'margin-top: 1em;' })
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
