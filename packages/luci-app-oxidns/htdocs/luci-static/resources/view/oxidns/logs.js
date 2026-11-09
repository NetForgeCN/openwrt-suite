'use strict';
'require view';
'require rpc';
'require poll';

var callLogsRecent = rpc.declare({
	object: 'luci.oxidns',
	method: 'logs_recent',
	params: [ 'limit' ],
	expect: {}
});

var state = {
	lines: [],
	pending: [],
	rawLines: [],
	paused: false,
	followTail: true,
	limit: 100,
	clearBaseline: null,
	filters: {
		keyword: '',
		plugin: '',
		qtype: '',
		rcode: ''
	}
};

var FILTER_FIELDS = [ 'plugin', 'qtype', 'rcode' ];

var FIELD_RES = {
	plugin: /(?:^|\s)plugin=(\S+)/,
	qtype: /(?:^|\s)qtype=(\S+)/,
	rcode: /(?:^|\s)rcode=(\S+)/
};

function byId(id) {
	return document.getElementById(id);
}

function normalizeLines(result) {
	var lines = result && result.lines;
	return Array.isArray(lines) ? lines : [];
}

function extractField(line, field) {
	var match = FIELD_RES[field].exec(line);
	return match ? match[1] : null;
}

function distinctValues(lines, field) {
	var seen = {};
	var values = [];

	for (var i = 0; i < lines.length; i++) {
		var value = extractField(lines[i], field);
		if (value && !seen[value]) {
			seen[value] = true;
			values.push(value);
		}
	}

	return values.sort();
}

function applyFilters(lines) {
	var f = state.filters;
	var keyword = f.keyword.toLowerCase();

	if (!keyword && !f.plugin && !f.qtype && !f.rcode)
		return lines;

	var filtered = [];

	for (var i = 0; i < lines.length; i++) {
		var line = lines[i];
		var keep = true;

		if (keyword && line.toLowerCase().indexOf(keyword) < 0)
			keep = false;

		for (var j = 0; keep && j < FILTER_FIELDS.length; j++) {
			var field = FILTER_FIELDS[j];
			var want = f[field];

			if (want && extractField(line, field) !== want)
				keep = false;
		}

		if (keep)
			filtered.push(line);
	}

	return filtered;
}

function trimClearedLines(lines) {
	var baseline = state.clearBaseline;
	var remove = 0;

	if (!baseline || !baseline.length)
		return lines;

	for (var i = Math.min(baseline.length, lines.length); i > 0; i--) {
		var match = true;

		for (var j = 0; j < i; j++) {
			if (baseline[baseline.length - i + j] !== lines[j]) {
				match = false;
				break;
			}
		}

		if (match) {
			remove = i;
			break;
		}
	}

	if (remove > 0)
		return lines.slice(remove);

	return lines;
}

function afterPaint(fn) {
	if (window.requestAnimationFrame)
		window.requestAnimationFrame(fn);
	else
		window.setTimeout(fn, 0);
}

function isNearBottom(node) {
	return node.scrollHeight - node.scrollTop - node.clientHeight < 24;
}

function scrollLogToBottom() {
	var log = byId('oxidns-log-lines');
	if (log)
		log.scrollTop = log.scrollHeight;
}

function updateFilterSummary() {
	var node = byId('oxidns-log-filter-summary');
	if (!node)
		return;

	var total = state.lines.length;
	var shown = applyFilters(state.lines).length;

	if (shown === total)
		node.textContent = _('%d lines').format(total);
	else
		node.textContent = _('%d of %d lines').format(shown, total);
}

function renderLines() {
	var log = byId('oxidns-log-lines');
	if (!log)
		return;

	var visible = applyFilters(state.lines);
	var shouldFollow = state.followTail || isNearBottom(log);
	log.textContent = visible.join('\n');
	updateFilterSummary();

	if (shouldFollow) {
		state.followTail = true;
		afterPaint(scrollLogToBottom);
	}
}

function updateFilterOptions() {
	for (var i = 0; i < FILTER_FIELDS.length; i++) {
		var field = FILTER_FIELDS[i];
		var select = byId('oxidns-log-filter-' + field);
		if (!select)
			continue;

		var values = distinctValues(state.lines, field);
		var signature = values.join('\n');
		if (select.getAttribute('data-signature') === signature)
			continue;
		select.setAttribute('data-signature', signature);

		while (select.firstChild)
			select.removeChild(select.firstChild);

		select.appendChild(E('option', { 'value': '' }, _('All')));

		for (var j = 0; j < values.length; j++)
			select.appendChild(E('option', { 'value': values[j] }, values[j]));

		if (state.filters[field] && values.indexOf(state.filters[field]) < 0)
			state.filters[field] = '';
		select.value = state.filters[field];
	}
}

function refreshLogs() {
	return L.resolveDefault(callLogsRecent(state.limit), null).then(function(result) {
		if (!result || result.ok === false)
			return;

		state.rawLines = normalizeLines(result);

		var lines = trimClearedLines(state.rawLines);

		if (state.paused)
			state.pending = lines;
		else
			state.lines = lines;

		updateFilterOptions();
		renderLines();
	});
}

function setPaused(paused) {
	state.paused = paused;
	if (!paused && state.pending.length) {
		state.lines = state.pending;
		state.pending = [];
	}
	updatePauseButton();
	renderLines();
}

function togglePaused() {
	return setPaused(!state.paused);
}

function clearLogs() {
	var currentLines = state.paused && state.pending.length
		? state.pending.slice()
		: state.lines.slice();
	var baseline = state.rawLines.length
		? state.rawLines.slice()
		: currentLines;

	if (baseline.length)
		state.clearBaseline = baseline;

	state.lines = [];
	state.pending = [];
	state.followTail = true;
	renderLines();
}

function resetFilters() {
	state.filters = { keyword: '', plugin: '', qtype: '', rcode: '' };

	var keyword = byId('oxidns-log-filter-keyword');
	if (keyword)
		keyword.value = '';

	for (var i = 0; i < FILTER_FIELDS.length; i++) {
		var select = byId('oxidns-log-filter-' + FILTER_FIELDS[i]);
		if (select)
			select.value = '';
	}

	renderLines();
}

function updatePauseButton() {
	var button = byId('oxidns-log-pause-toggle');
	if (!button)
		return;

	button.textContent = state.paused ? _('Resume') : _('Pause');
	button.className = 'btn cbi-button cbi-button-%s'.format(state.paused ? 'positive' : 'neutral');
}

function controlButton(label, handler, style) {
	return E('button', {
		'class': 'btn cbi-button cbi-button-%s'.format(style || 'neutral'),
		'click': function(ev) {
			ev.preventDefault();
			return handler();
		}
	}, label);
}

function filterLabel(text) {
	return E('span', {
		'style': 'align-self: center; color: #888; font-size: 12px; white-space: nowrap;'
	}, text);
}

function filterBar() {
	var keywordInput = E('input', {
		'id': 'oxidns-log-filter-keyword',
		'class': 'cbi-input-text',
		'type': 'text',
		'placeholder': _('Keyword (qname, domain, text...)'),
		'style': 'flex: 1 1 220px; min-width: 180px;',
		'input': function(ev) {
			state.filters.keyword = ev.target.value;
			renderLines();
		}
	});

	var bar = E('div', {
		'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-bottom: .75em;'
	}, [ keywordInput ]);

	var fieldLabels = {
		plugin: _('Plugin'),
		qtype: _('QType'),
		rcode: _('RCode')
	};

	for (var i = 0; i < FILTER_FIELDS.length; i++) {
		(function(field) {
			bar.appendChild(filterLabel(fieldLabels[field]));
			bar.appendChild(E('select', {
				'id': 'oxidns-log-filter-' + field,
				'class': 'cbi-input-select',
				'style': 'max-width: 180px;',
				'change': function(ev) {
					state.filters[field] = ev.target.value;
					renderLines();
				}
			}, E('option', { 'value': '' }, _('All'))));
		})(FILTER_FIELDS[i]);
	}

	bar.appendChild(controlButton(_('Reset'), resetFilters, 'neutral'));

	return bar;
}

return view.extend({
	load: function() {
		return Promise.resolve({
			ok: true,
			source: 'logread',
			lines: []
		});
	},

	render: function(initial) {
		state.lines = normalizeLines(initial);
		state.pending = [];
		state.rawLines = state.lines.slice();
		state.paused = false;
		state.followTail = true;
		state.clearBaseline = null;
		state.filters = { keyword: '', plugin: '', qtype: '', rcode: '' };
		window.setTimeout(refreshLogs, 0);
		poll.add(refreshLogs, 1);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS Logs')),
			E('div', { 'class': 'cbi-map-descr' },
				_('View recent OxiDNS entries from OpenWrt logread. Use the filters to narrow down entries by keyword, plugin, query type or response code.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', {
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-bottom: 1em;'
				}, [
					E('button', {
						'id': 'oxidns-log-pause-toggle',
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function(ev) {
							ev.preventDefault();
							return togglePaused();
						}
					}, _('Pause')),
					controlButton(_('Refresh'), refreshLogs, 'action'),
					controlButton(_('Clear'), clearLogs, 'negative'),
					E('span', {
						'id': 'oxidns-log-filter-summary',
						'style': 'align-self: center; margin-left: auto; color: #888; font-size: 12px;'
					}, '')
				]),
				filterBar(),
				E('pre', {
					'id': 'oxidns-log-lines',
					'scroll': function(ev) {
						state.followTail = isNearBottom(ev.target);
					},
					'style': 'min-height: 560px; max-height: 72vh; overflow: auto; margin-top: .25em; padding: 1em; background: #111; color: #ddd; white-space: pre-wrap; overflow-wrap: anywhere;'
				}, state.lines.join('\n'))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
