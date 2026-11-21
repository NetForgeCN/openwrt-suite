'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callStatus = rpc.declare({ object: 'luci.oxidnsplus', method: 'status', expect: {} });
var callSettings = rpc.declare({ object: 'luci.oxidnsplus', method: 'settings_read', expect: {} });
var callSaveSettings = rpc.declare({ object: 'luci.oxidnsplus', method: 'settings_save', params: ['enabled','config_path','api_base','api_user','api_pass','cache_tag','dns_target','watch_list','mode','tick','grace','refresh_delay','min_ttl','min_interval','max_interval','jitter','retry_base','retry_max','retry_max_count','log_level'], expect: {} });
var callListRead = rpc.declare({ object: 'luci.oxidnsplus', method: 'warm_list_read', expect: {} });
var callListSave = rpc.declare({ object: 'luci.oxidnsplus', method: 'warm_list_save', params: ['content'], expect: {} });
var callLog = rpc.declare({ object: 'luci.oxidnsplus', method: 'log', params: ['lines'], expect: {} });

var FIELDS = ['enabled','config_path','api_base','api_user','api_pass','cache_tag','dns_target','watch_list','mode','tick','grace','refresh_delay','min_ttl','min_interval','max_interval','jitter','retry_base','retry_max','retry_max_count','log_level'];

function pad(n) { return n < 10 ? '0' + n : '' + n; }
function fmtTime(iso) {
	if (!iso || iso === '-') return '-';
	var d = new Date(iso);
	if (isNaN(d.getTime())) return iso;
	return pad(d.getMonth()+1)+'/'+pad(d.getDate())+' '+pad(d.getHours())+':'+pad(d.getMinutes())+':'+pad(d.getSeconds());
}
function esc(s) {
	return String(s == null ? '' : s).replace(/&/g,'&amp;').replace(/</g,'&lt;')
		.replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function resultLabel(r) {
	var m = {
		'seeded': _('Seeded'), 'refresh-ok': _('Refreshed'), 'ttl-changed': _('TTL followed'),
		'failed': _('Failed'), 'refresh-failed': _('Retrying'), 'short-ttl-fixed': _('Short TTL fixed')
	};
	return m[r] || r || '-';
}

return view.extend({
	load: function() {
		return Promise.all([ callStatus(), callSettings(), callListRead() ]);
	},

	render: function(data) {
		var status = data[0] && data[0].status ? data[0].status : null;
		var settings = data[1] || {};
		var listData = data[2] || {};

		var head = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('OxiDNS Plus - TTL-adaptive Prewarming')),
			E('p', { 'class': 'cbi-map-descr' },
				_('Keeps your important domains warm by watching each cached TTL. Just after a fresh entry expires, a single query is sent to OxiDNS so its native lazy cache refreshes in the background. No cache is deleted, no upstream is queried by this add-on, and TTL changes are followed automatically.'))
		]);

		// ---- Status card ----
		var statusBody = E('div', { id: 'oxp-status', 'class': 'cbi-section' });
		var refreshBtn = E('button', { 'class': 'btn', 'click': function() {
			callStatus().then(function(res) { renderStatus(res && res.status ? res.status : null); });
		}}, _('Refresh'));

		var view = this;
		function renderStatus(st) {
			if (!st) {
				statusBody.innerHTML = '<p style="color:#c00;">' + _('Prewarmer status unavailable. Is the service running and enabled?') + '</p>';
				return;
			}
			var stats = st.stats || {};
			var h = '<div style="display:flex;flex-wrap:wrap;gap:1.2em;margin:.3em 0 .8em;">'
				+ '<span><b>' + _('Probes') + ':</b> ' + (stats.probes||0) + '</span>'
				+ '<span><b>' + _('Refreshed') + ':</b> ' + (stats.refresh_ok||0) + '</span>'
				+ '<span><b>' + _('Seeds') + ':</b> ' + (stats.seeds||0) + '</span>'
				+ '<span><b>' + _('Failed') + ':</b> ' + (stats.refresh_failed||0) + '</span>'
				+ '<span><b>' + _('Domains') + ':</b> ' + ((st.tasks||[]).length) + '</span>'
				+ '<span><b>' + _('Updated') + ':</b> ' + esc(fmtTime(st.updated_at)) + '</span>'
				+ '</div>';
			h += '<table class="cbi-table" style="width:100%;border-collapse:collapse;">'
				+ '<tr><th>' + _('Domain') + '</th><th>' + _('Type') + '</th><th>' + _('TTL') + '</th>'
				+ '<th>' + _('Remaining') + '</th><th>' + _('Next probe') + '</th>'
				+ '<th>' + _('Source') + '</th><th>' + _('Result') + '</th></tr>';
			var tasks = st.tasks || [];
			for (var i = 0; i < tasks.length; i++) {
				var t = tasks[i];
				h += '<tr>'
					+ '<td>' + esc(t.domain) + '</td>'
					+ '<td>' + esc(t.qtype) + '</td>'
					+ '<td>' + esc(t.ttl) + 's</td>'
					+ '<td>' + esc(t.remaining_ttl) + 's</td>'
					+ '<td>' + esc(fmtTime(t.next_probe)) + '</td>'
					+ '<td>' + (t.in === 'watch-list' ? _('Watch list') : _('Auto')) + '</td>'
					+ '<td>' + esc(resultLabel(t.last_result)) + (t.last_error ? ' <span style="color:#c00;">(' + esc(t.last_error) + ')</span>' : '') + '</td>'
					+ '</tr>';
			}
			h += '</table>';
			statusBody.innerHTML = h;
		}
		renderStatus(status);
		poll.add(function() {
			callStatus().then(function(res) { renderStatus(res && res.status ? res.status : null); });
		}, 5);

		// ---- Watch list editor ----
		var ta = E('textarea', { id: 'oxp-watchlist', 'class': 'cbi-input-textarea', style: 'width:100%;min-height:120px;font-family:monospace;' });
		ta.value = listData.content || '';
		var saveListBtn = E('button', { 'class': 'btn btn-primary', 'click': function() {
			callListSave(ta.value).then(function() { ui.showNotification(_('Watch list saved; prewarmer restarted.')); });
		}}, _('Save watch list'));
		var listCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Watch list')),
			E('p', { 'class': 'cbi-section-descr' }, _('One "domain [A|AAAA]" per line. Only these are prewarmed in list mode. Use "all" mode to prewarm every cached domain instead.')),
			ta, E('div', { style: 'margin-top:.5em;' }, saveListBtn)
		]);

		// ---- Settings grid ----
		// Bound directly to the rpcd settings API (which writes this add-on's
		// own UCI package). Rendered as a simple field grid for robustness.
		var grid = E('div', { 'class': 'cbi-section' });
		var gridHtml = '<h3>' + _('Settings') + '</h3><table class="cbi-table" style="width:100%;border-collapse:collapse;">';
		var labels = {
			enabled: _('Enabled'), mode: _('Mode'), cache_tag: _('Cache tag'), dns_target: _('DNS target'),
			watch_list: _('Watch list path'), tick: _('Reconcile tick (s)'), grace: _('Grace after expiry (s)'),
			refresh_delay: _('Refresh wait (ms)'), min_ttl: _('Min TTL (s)'), min_interval: _('Min interval (s)'),
			max_interval: _('Max interval (s)'), jitter: _('Jitter (s)'), retry_base: _('Retry base (s)'),
			retry_max: _('Retry max (s)'), retry_max_count: _('Retry max count'), api_base: _('API base (override)'),
			api_user: _('API user (override)'), api_pass: _('API password'), config_path: _('OxiDNS config path'),
			log_level: _('Log level')
		};
		var fields = [];
		for (var k = 0; k < FIELDS.length; k++) {
			var f = FIELDS[k];
			gridHtml += '<tr><td style="padding:.25em .5em;">' + esc(labels[f] || f) + '</td>'
				+ '<td style="padding:.25em .5em;"><input class="cbi-input-text" data-field="' + f + '" type="'
				+ (f === 'api_pass' ? 'password' : 'text') + '" value="' + esc(settings[f] || '') + '" style="width:100%;"'
				+ (f === 'enabled' ? ' placeholder="1 or 0"' : '') + '></td></tr>';
			fields.push(f);
		}
		gridHtml += '</table>';
		grid.innerHTML = gridHtml;
		var saveSettingsBtn = E('button', { 'class': 'btn btn-primary', style: 'margin-top:.6em;', 'click': function() {
			var payload = {};
			var inputs = grid.querySelectorAll('input[data-field]');
			for (var i = 0; i < inputs.length; i++) payload[inputs[i].getAttribute('data-field')] = inputs[i].value;
			callSaveSettings(payload).then(function() { ui.showNotification(_('Settings saved; prewarmer restarted.')); });
		}}, _('Save settings'));
		grid.appendChild(saveSettingsBtn);

		// ---- Log card ----
		var logBox = E('pre', { id: 'oxp-log', style: 'max-height:260px;overflow:auto;background:#f6f6f6;padding:.6em;font-size:12px;' }, _('Loading log...'));
		callLog('120').then(function(res) { logBox.textContent = (res && res.lines) ? res.lines : _('(no log entries)'); });

		return E('div', {}, [
			head,
			E('div', { 'class': 'cbi-section', style: 'display:flex;align-items:center;justify-content:space-between;' }, [
				E('h3', { style: 'margin:0;' }, _('Live status')), refreshBtn
			]),
			statusBody,
			listCard,
			grid,
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('Recent log')), logBox ])
		]);
	}
});
