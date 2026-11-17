'use strict';
'require view';
'require rpc';
'require ui';

var callRulesStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_status',
	expect: {}
});

var callRulesCheck = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_check',
	expect: {}
});

var callRulesUpdate = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_update',
	expect: {}
});

var callRulesRestore = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_restore',
	expect: {}
});

var callProgress = rpc.declare({
	object: 'luci.oxidns',
	method: 'core_progress',
	expect: {}
});

var statusState = {};

function valueOrDash(value) {
	if (value === null || value === undefined || value === '')
		return '-';
	return value;
}

function formatBytes(bytes) {
	var size = parseInt(bytes, 10) || 0;
	if (size <= 0)
		return '-';
	if (size < 1024)
		return '%d B'.format(size);
	if (size < 1048576)
		return '%.1f KiB'.format(size / 1024);
	return '%.1f MiB'.format(size / 1048576);
}

function callWithRpcTimeout(call, seconds) {
	if (!seconds)
		return call();

	var previousTimeout = L.env.rpctimeout;
	L.env.rpctimeout = seconds;

	var restore = function() {
		if (previousTimeout === undefined)
			delete L.env.rpctimeout;
		else
			L.env.rpctimeout = previousTimeout;
	};

	return call().then(function(result) {
		restore();
		return result;
	}, function(err) {
		restore();
		throw err;
	});
}

function renderRow(label, value, id) {
	var valueAttrs = { 'class': 'td left' };
	if (id)
		valueAttrs.id = id;

	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 33%' }, label),
		E('div', valueAttrs, valueOrDash(value))
	]);
}

function renderRulesError(result) {
	var message = (result && (result.message || result.error)) || _('Rule operation failed');
	var detail = result && (result.detail || result.details);
	var children = [
		E('p', {}, E('strong', {}, _('Rule operation failed')))
	];

	if (detail)
		children.push(E('p', { 'class': 'small' }, detail));
	if (result && result.code)
		children.push(E('p', { 'class': 'small' }, _('Error code') + ': ' + result.code));

	if (!detail && !(result && result.code))
		children.push(E('p', {}, message));

	return E('div', {}, children);
}

function replaceContent(node, content) {
	if (!node)
		return;

	while (node.firstChild)
		node.removeChild(node.firstChild);

	if (content === null || content === undefined)
		return;

	if (Array.isArray(content)) {
		for (var i = 0; i < content.length; i++)
			node.appendChild(content[i]);
	} else if (content.nodeType) {
		node.appendChild(content);
	} else {
		node.textContent = String(content);
	}
}

function showProgressModal(label) {
	var statusNode = E('p', {}, label);
	var logNode = E('pre', {
		'style': [
			'box-sizing: border-box',
			'width: 100%',
			'min-height: 16em',
			'max-height: 40vh',
			'overflow: auto',
			'padding: 1em',
			'border: 1px solid #ccc',
			'background: #111',
			'color: #eee',
			'white-space: pre-wrap',
			'font-family: monospace',
			'font-size: 12px',
			'line-height: 1.45'
		].join(';')
	}, _('Waiting for command output...'));
	var resultNode = E('div', {});
	var closeButton = E('button', {
		'class': 'btn cbi-button cbi-button-neutral',
		'disabled': 'disabled',
		'click': function(ev) {
			ev.preventDefault();
			ui.hideModal();
		}
	}, _('Close'));

	ui.showModal(_('OxiDNS'), [
		statusNode,
		E('div', { 'class': 'cbi-value-title', 'style': 'margin-bottom: .35em;' }, _('Command output')),
		logNode,
		resultNode,
		E('div', { 'class': 'right', 'style': 'margin-top: 1em;' }, closeButton)
	]);

	return { status: statusNode, log: logNode, result: resultNode, closeButton: closeButton };
}

function finishProgress(nodes, statusText, resultContent) {
	if (nodes.status)
		nodes.status.textContent = statusText;
	replaceContent(nodes.result, resultContent);
	if (nodes.closeButton) {
		nodes.closeButton.disabled = false;
		nodes.closeButton.removeAttribute('disabled');
	}
}

function refreshProgressLog(logNode) {
	return L.resolveDefault(callProgress(), null).then(function(result) {
		if (!result || result.ok === false)
			return;
		logNode.textContent = result.text || _('Waiting for command output...');
		logNode.scrollTop = logNode.scrollHeight;
	});
}

function runRulesAction(label, call, timeout) {
	var nodes = showProgressModal(label);
	var stopped = false;
	var timer = window.setInterval(function() {
		if (!stopped)
			refreshProgressLog(nodes.log);
	}, 1000);
	window.setTimeout(function() {
		if (!stopped)
			refreshProgressLog(nodes.log);
	}, 500);

	return L.resolveDefault(callWithRpcTimeout(call, timeout), null).then(function(result) {
		stopped = true;
		window.clearInterval(timer);
		return refreshProgressLog(nodes.log).then(function() {
			if (!result || result.ok === false) {
				finishProgress(nodes, _('Rule operation failed'), renderRulesError(result || {}));
				return;
			}
			finishProgress(nodes, _('Rule operation completed.'), E('p', {}, _('Rule operation completed.')));
			ui.addNotification(null, E('p', {}, _('Rule operation completed.')), 'info');
			return loadStatus();
		});
	}).catch(function(err) {
		stopped = true;
		window.clearInterval(timer);
		var errorResult = { 'message': (err && err.message) || String(err) };
		finishProgress(nodes, _('Rule operation failed'), renderRulesError(errorResult));
	});
}

function loadStatus() {
	return L.resolveDefault(callRulesStatus(), {}).then(function(status) {
		statusState = status || {};
		renderStatus();
	});
}

function renderStatus() {
	var summary = document.getElementById('oxidns-rules-summary');
	if (summary) {
		replaceContent(summary, [
			renderRow(_('Installed version'), statusState.installed_version, 'oxidns-rules-installed'),
			renderRow(_('Baseline version'), statusState.baseline_version, 'oxidns-rules-baseline'),
			renderRow(_('Repository'), statusState.repository, 'oxidns-rules-repository'),
			renderRow(_('Working copy'), statusState.rules_dir, 'oxidns-rules-dir')
		]);
	}

	var body = document.getElementById('oxidns-rules-files');
	if (body)
		replaceContent(body, renderFileRows());
}

function stateText(file) {
	if (!file || !file.present)
		return _('Missing');
	if (file.matches_baseline)
		return _('Bundled');
	return _('Local copy');
}

function renderFileRows() {
	var files = (statusState && statusState.files) || [];
	var rows = [
		E('div', { 'class': 'tr table-titles' }, [
			E('div', { 'class': 'th' }, _('File')),
			E('div', { 'class': 'th' }, _('Lines')),
			E('div', { 'class': 'th' }, _('Size')),
			E('div', { 'class': 'th' }, _('State'))
		])
	];

	for (var i = 0; i < files.length; i++) {
		var file = files[i];
		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td left' }, file.name),
			E('div', { 'class': 'td' }, valueOrDash(file.lines)),
			E('div', { 'class': 'td' }, formatBytes(file.bytes)),
			E('div', { 'class': 'td' }, stateText(file))
		]));
	}

	if (!files.length)
		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td', 'colspan': 4 }, '-')
		]));

	return rows;
}

function handleCheck() {
	return L.resolveDefault(callWithRpcTimeout(callRulesCheck, 300), null).then(function(result) {
		if (!result || result.ok === false) {
			ui.addNotification(null, renderRulesError(result || {}), 'danger');
			return;
		}

		var rows = [
			renderRow(_('Installed version'), result.current_version),
			renderRow(_('Latest version'), result.latest_version),
			renderRow(_('Baseline version'), result.baseline_version),
			renderRow(_('Release asset'), result.asset)
		];
		var buttons = [
			E('button', {
				'class': 'btn cbi-button cbi-button-neutral',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Close'))
		];

		if (result.update_available) {
			buttons.push(' ');
			buttons.push(E('button', {
				'class': 'btn cbi-button cbi-button-positive',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
					return runRulesAction(_('Updating rule subscriptions...'), callRulesUpdate, 600);
				}
			}, _('Update now')));
		}

		ui.showModal(_('Rule Subscriptions'), [
			E('div', { 'class': 'table cbi-section-table' }, rows),
			E('p', {}, result.update_available ? _('Rule update available.') : _('No rule update available.')),
			E('div', { 'class': 'right', 'style': 'margin-top: 1em;' }, buttons)
		]);
	});
}

function handleRestore() {
	return new Promise(function(resolve) {
		ui.showModal(_('Restore baseline'), [
			E('p', {}, _('This overwrites every rule file in the working copy with the bundled baseline.')),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'click': function(ev) {
						ev.preventDefault();
						ui.hideModal();
						resolve();
					}
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': function(ev) {
						ev.preventDefault();
						ui.hideModal();
						resolve(runRulesAction(_('Restoring rules from the bundled baseline...'),
							callRulesRestore, 300));
					}
				}, _('Confirm'))
			])
		]);
	});
}

function renderStatusRows() {
	return [
		renderRow(_('Installed version'), statusState.installed_version, 'oxidns-rules-installed'),
		renderRow(_('Baseline version'), statusState.baseline_version, 'oxidns-rules-baseline'),
		renderRow(_('Repository'), statusState.repository, 'oxidns-rules-repository'),
		renderRow(_('Working copy'), statusState.rules_dir, 'oxidns-rules-dir')
	];
}

function actionButton(label, handler, style) {
	return E('button', {
		'class': 'btn cbi-button cbi-button-%s'.format(style || 'neutral'),
		'click': function(ev) {
			ev.preventDefault();
			return handler();
		}
	}, label);
}

return view.extend({
	load: function() {
		return L.resolveDefault(callRulesStatus(), {});
	},

	render: function(status) {
		statusState = status || {};

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Rule Subscriptions')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Domain lists used for China/ad split and ad blocking. The working copy is seeded from the bundled baseline at boot and can be updated from a published release.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Versions')),
				E('div', { 'class': 'table cbi-section-table', 'id': 'oxidns-rules-summary' },
					renderStatusRows())
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Actions')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Updates are downloaded from the repository release, verified with SHA256 and validated with oxidns check before they replace the working copy. Restoring the baseline works offline.')),
				E('div', { 'class': 'cbi-button-row', 'style': 'display: flex; flex-wrap: wrap; gap: .5em;' }, [
					actionButton(_('Check for updates'), handleCheck, 'action'),
					actionButton(_('Update now'), function() {
						return runRulesAction(_('Updating rule subscriptions...'), callRulesUpdate, 600);
					}, 'positive'),
					actionButton(_('Restore baseline'), handleRestore, 'neutral'),
					actionButton(_('Refresh'), function() {
						return loadStatus();
					}, 'neutral')
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Rule files')),
				E('div', { 'class': 'table cbi-section-table', 'id': 'oxidns-rules-files' },
					renderFileRows())
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});

