'use strict';
'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require view';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

var callFileStat = rpc.declare({
	object: 'file',
	method: 'stat',
	params: ['path'],
	expect: { '': {} }
});

var callFileRead = rpc.declare({
	object: 'file',
	method: 'read',
	params: ['path'],
	expect: {}
});

var callExec = rpc.declare({
	object: 'file',
	method: 'exec',
	params: ['command', 'params'],
	expect: {}
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('airplay2'), {}).then(function (res) {
		var instances = res && res.airplay2 && res.airplay2.instances;
		if (!instances || !instances.instance1)
			return false;
		return instances.instance1.running === true;
	});
}

/* Build DOM nodes instead of an HTML string: no innerHTML means no chance of
 * injecting markup if a translated label or a tool's output ever changes. */
function renderStatus(isRunning) {
	return E('em', {}, [
		E('span', { 'style': 'color:' + (isRunning ? 'green' : 'red') }, [
			E('strong', {}, 'Airplay2 ' + (isRunning ? _('RUNNING') : _('NOT RUNNING')))
		])
	]);
}

function getSoundCards() {
	var alsaPromise = callFileRead('/proc/asound/cards').then(function (res) {
		var content = (res && typeof res.data === 'string') ? res.data : '';
		var cards = [];
		content.split('\n').forEach(function (line) {
			var match = line.match(/^\s*(\d+)\s+\[[^\]]+\]:\s*(.+)$/);
			if (match) {
				cards.push({
					type: 'alsa',
					id: match[1],
					desc: match[2]
				});
			}
		});
		return cards;
	}).catch(function (e) {
		console.warn('airplay2: cannot read /proc/asound/cards', e);
		return [];
	});

	var bluetoothPromise = callFileStat('/usr/bin/bluealsa-aplay').then(function (stat) {
		if (!stat)
			return [];
		return callExec('/usr/bin/bluealsa-aplay', ['-l']).then(function (res) {
			var devices = [];
			if (res && res.code === 0 && typeof res.stdout === 'string') {
				res.stdout.trim().split('\n').forEach(function (line) {
					if (line.indexOf('audio') !== -1) {
						var match = line.match(/([0-9A-F]{2}(:[0-9A-F]{2}){5}).*\[([^\]]+)\]/i);
						if (match) {
							devices.push({ type: 'bluealsa', id: match[1], desc: match[3] });
						}
					}
				});
			}
			return devices;
		});
	}).catch(function (e) {
		console.warn('airplay2: cannot list BlueALSA devices', e);
		return [];
	});

	return Promise.all([alsaPromise, bluetoothPromise]).then(function (results) {
		return results[0].concat(results[1]);
	});
}

return view.extend({
	load: function () {
		/* Fetch device data here so render() stays free of RPC side effects. */
		return getSoundCards();
	},

	render: function (cards) {
		var self = this;
		var m = new form.Map('airplay2', _('Airplay 2'),
			_('AirPlay 2 is a simple and easy-to-use AirPlay audio player.'));

		var s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function () {
			var statusEl = E('p', {
				'id': 'service_status',
				'role': 'status',
				'aria-live': 'polite'
			}, _('Collecting data...'));

			function stopStatusPoll() {
				if (self._statusPollFn != null && typeof poll.remove === 'function') {
					poll.remove(self._statusPollFn);
					self._statusPollFn = null;
				}
			}

			/* LuCI's poll.add() takes and removes a callback function - it does
			 * not return a removable handle. Only one poller per view instance,
			 * and never after the view has been detached. */
			if (self._statusPollFn == null) {
				self._statusPollFn = function () {
					if (!statusEl.parentNode) {
						stopStatusPoll();
						return;
					}
					return getServiceStatus().then(function (running) {
						dom.content(statusEl, renderStatus(running));
					});
				};
				poll.add(self._statusPollFn, 3);
			}
			self._stopStatusPoll = stopStatusPoll;

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [statusEl]);
		};
		self._stopAirplay2StatusPoll = self._stopStatusPoll;

		s = m.section(form.NamedSection, '@airplay2[0]', 'airplay2');
		s.anonymous = true;

		var o;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;

		o = s.option(form.Value, 'name', _('Airplay Name'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'interpolation', _('Interpolation'));
		o.default = 'basic';
		o.value('basic', _('Internal Basic Resampler'));
		o.value('soxr', _('High quality SoX Resampler'));

		o = s.option(form.Value, 'port', _('Port'));
		o.default = '5050';
		o.datatype = 'port';

		var soundcardOpt = s.option(form.ListValue, 'alsa_output_device', _('Alsa Output Device'));
		soundcardOpt.default = '';
		soundcardOpt.value('', _('default'));
		soundcardOpt.value('bluealsa', _('Default Bluetooth Audio (BlueALSA)'));
		if (Array.isArray(cards)) {
			cards.forEach(function (card) {
				if (card.type === 'bluealsa') {
					soundcardOpt.value('bluealsa:DEV=' + card.id, card.desc + ' (' + card.id + ')');
				} else {
					soundcardOpt.value('hw:' + card.id, card.desc + ' (hw:' + card.id + ')');
				}
			});
		}

		o = s.option(form.ListValue, 'alsa_mixer_control_name', _('Alsa Mixer Control Name'));
		o.default = '';
		o.value('', _('default (software volume)'));
		o.value('PCM', _('PCM'));
		o.value('Speaker', _('Speaker'));

		o = s.option(form.ListValue, 'alsa_output_rate', _('Alsa Output Rate'));
		o.default = 'auto';
		o.value('auto', _('auto'));
		o.value('44100', _('44.1kHz'));
		o.value('88200', _('88.2kHz'));
		o.value('176400', _('176.4kHz'));
		o.value('352800', _('352.8kHz'));

		o = s.option(form.Value, 'alsa_buffer_length', _('Alsa Buffer Length'));
		o.default = '6615';

		o = s.option(form.Value, 'sesctl_session_timeout', _('Session timeout'));
		o.default = '120';

		o = s.option(form.ListValue, 'sesctl_session_interruption', _('Allow session interruption'));
		o.default = 'no';
		o.value('no', _('Not allow'));
		o.value('yes', _('Allow'));

		return m.render();
	},

	handleSaveApply: function (ev, mode) {
		var self = this;
		if (typeof self._stopAirplay2StatusPoll === 'function')
			self._stopAirplay2StatusPoll();
		return this.super('handleSaveApply', [ev, mode]);
	}
});
