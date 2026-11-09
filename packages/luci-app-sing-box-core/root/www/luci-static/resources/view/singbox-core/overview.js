'use strict';
'require view';
'require rpc';
'require poll';
'require fs';
'require ui';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

var BIN = '/usr/libexec/sing-box-core/sing-box';

function isRunning() {
	return callServiceList('singbox_core').then(function(res) {
		var svc = (res && res.singbox_core) || {};
		var inst = svc.instances || {};

		for (var k in inst)
			if (inst[k].running)
				return true;

		return false;
	}).catch(function() { return false; });
}

function readVersion() {
	return fs.exec(BIN, [ 'version' ]).then(function(res) {
		var m = (res.stdout || '').match(/version ([0-9]+\.[0-9]+\.[0-9]+[^\s]*)/);
		return m ? m[1] : _('未知');
	}).catch(function() { return _('未安装'); });
}

function readLog() {
	return fs.exec('/sbin/logread', [ '-e', 'sing-box-core' ]).then(function(res) {
		var lines = (res.stdout || '').trim().split('\n');
		return lines.slice(-120).join('\n');
	}).catch(function(err) {
		return _('读取日志失败：') + err;
	});
}

return view.extend({
	load: function() {
		return Promise.all([ isRunning(), readVersion(), readLog() ]);
	},

	render: function(data) {
		var running = data[0], version = data[1], log = data[2];

		var stateEl = E('span', {
			'style': 'font-weight:500;color:' + (running ? '#0f6e56' : '#a32d2d')
		}, running ? _('运行中') : _('已停止'));

		var logEl = E('pre', {
			'style': 'max-height:320px;overflow:auto;white-space:pre-wrap;font-size:12px;' +
				'background:var(--background-color-low,#f7f7f7);padding:8px;border-radius:6px;margin:0'
		}, log || _('（暂无日志）'));

		var rulesetEl = E('div', { 'style': 'font-size:13px;line-height:1.8' },
			_('规则集由内核在启动时从 SagerNet 官方源自动下载，并缓存到 /etc/sing-box-core/cache.db。'));

		function act(cmd) {
			return fs.exec('/etc/init.d/sing-box-core', [ cmd ]).then(function() {
				return new Promise(function(r) { window.setTimeout(r, 1500); });
			}).then(function() {
				return isRunning();
			}).then(function(r) {
				stateEl.textContent = r ? _('运行中') : _('已停止');
				stateEl.style.color = r ? '#0f6e56' : '#a32d2d';
				return readLog();
			}).then(function(t) {
				logEl.textContent = t || _('（暂无日志）');
			}).catch(function(err) {
				ui.addNotification(null, E('p', String(err)), 'error');
			});
		}

		poll.add(function() {
			return Promise.all([ isRunning(), readLog() ]).then(function(r) {
				stateEl.textContent = r[0] ? _('运行中') : _('已停止');
				stateEl.style.color = r[0] ? '#0f6e56' : '#a32d2d';
				logEl.textContent = r[1] || _('（暂无日志）');
			});
		}, 5);

		return E([
			E('h2', null, _('sing-box-core 概览')),
			E('div', { 'class': 'cbi-section', 'style': 'padding:12px 0' }, [
				E('div', { 'style': 'margin-bottom:12px' }, [
					E('strong', null, _('状态')), '：', stateEl,
					E('span', { 'style': 'margin-left:16px;color:var(--text-color-low,#666)' },
						_('内核版本'), '：', version)
				]),
				E('div', { 'class': 'cbi-button-row' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, function() { return act('restart'); })
					}, _('重启服务')),
					E('button', {
						'class': 'cbi-button cbi-button-reset',
						'click': ui.createHandlerFn(this, function() { return act('stop'); })
					}, _('停止')),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() {
							return fs.exec('/usr/libexec/sing-box-core/apply.sh').then(function(res) {
								if (res.code !== 0)
									ui.addNotification(null,
										E('pre', { 'style': 'white-space:pre-wrap' },
											res.stderr || _('应用失败')), 'error');
								else
									ui.addNotification(null, E('p', _('配置已应用')), 'info');
							});
						})
					}, _('重新渲染并应用'))
				])
			]),

			E('h3', null, _('规则集')),
			E('div', { 'class': 'cbi-section', 'style': 'padding:8px 0 16px' }, rulesetEl),

			E('h3', null, _('日志')),
			E('div', { 'class': 'cbi-section' }, logEl)
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
