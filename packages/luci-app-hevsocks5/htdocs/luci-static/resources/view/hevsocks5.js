'use strict';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

var CONF = 'hev-socks5-server';
var CTL = '/usr/bin/hevsocks5-ctl';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

function callCtl(cmd, args) {
	return fs.exec(CTL, [ cmd ].concat(args || [])).then(function(res) {
		if (res && res.code !== 0)
			throw new Error(res.stderr || _('Command failed: %s').format(cmd));
		return res;
	});
}

function getStatus() {
	// Do not hide RPC failures behind L.resolveDefault(): an unavailable
	// service object must not be rendered as a clean "not running" state.
	return callServiceList(CONF).then(function(res) {
		var instances = (res && res[CONF] && res[CONF].instances) || {};
		var running = false;

		for (var name in instances)
			if (instances[name] && instances[name].running) {
				running = true;
				break;
			}

		return running;
	});
}

// Web Crypto may be missing or mocked to all-zero bytes in some embedded
// WebViews (that produced "AAAA..." credentials). Always ask the server to
// generate the value from /dev/urandom; never fall back to Math.random for
// authentication secrets.
function randomString(len) {
	return callCtl('rand', [ String(len) ]).then(function(res) {
		var value = String(res && res.stdout || '').trim();
		if (value.length !== len || !/^[A-Za-z0-9]+$/.test(value))
			throw new Error(_('Random generator returned an invalid value'));
		return value;
	});
}

// 把父类 render() 的结果统一收敛成单个 DOM 节点。LuCI 各版本的
// form.Value.render() 可能返回同步节点、Promise<Node>，个别实现还会返回
// 节点数组；后续一律走 Promise，避免把 Promise/数组当成节点去调用
// querySelector 而抛出 "node.querySelector is not a function"。
function renderedNode(x) {
	return Promise.resolve(x).then(function(node) {
		if (node && !node.querySelector && node.length)
			node = node[0];

		return node;
	});
}

var RandomValue = form.Value.extend({
	randLen: 16,

	render: function(index, section_id, in_table) {
		var self = this;

		return renderedNode(form.Value.prototype.render.call(this, index, section_id, in_table))
			.then(function(node) {
				if (!node || typeof node.querySelector !== 'function')
					return node;

				var input = node.querySelector('input');

				if (input) {
					var btn = E('button', {
						'class': 'btn',
						'type': 'button',
						'title': _('Generate a random value'),
					'click': function(ev) {
						ev.preventDefault();
						var trigger = ev.currentTarget;
						setButtonBusy(trigger, true);
						return randomString(self.randLen).then(function(value) {
							input.value = value;
							input.dispatchEvent(new Event('change', { bubbles: true }));
							setButtonBusy(trigger, false);
						}).catch(function(e) {
							setButtonBusy(trigger, false);
							notify(_('Operation failed'), 'error');
							showError(e);
						});
					}
				}, _('Generate'));

					var field = node.querySelector('.cbi-value-field') || node;
					field.appendChild(btn);
				}

				return node;
			});
	}
});

var PasswordValue = RandomValue.extend({
	render: function(index, section_id, in_table) {
		return renderedNode(RandomValue.prototype.render.call(this, index, section_id, in_table))
			.then(function(node) {
				if (!node || typeof node.querySelector !== 'function')
					return node;

				var input = node.querySelector('input');

				if (input) {
					input.type = 'password';

					var btn = E('button', {
						'class': 'btn',
						'type': 'button',
						'title': _('Show password'),
						'click': function(ev) {
							ev.preventDefault();
							var visible = input.type === 'text';
							input.type = visible ? 'password' : 'text';
							btn.title = visible ? _('Show password') : _('Hide password');
						}
					}, '👁');

					var field = node.querySelector('.cbi-value-field') || node;
					field.appendChild(btn);
				}

				return node;
			});
	}
});

function showError(e) {
	ui.showModal(_('Operation failed'), [
		E('p', {}, String(e && e.message ? e.message : e)),
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn',
				'type': 'button',
				'click': function() { ui.hideModal(); }
			}, _('Close'))
		])
	]);
}

// Visible feedback for every button: a busy label plus a result line, so a
// click is never silent even when the underlying action produces no output.
function setButtonBusy(btn, busy) {
	if (!btn)
		return;

	if (busy) {
		if (btn.dataset.hevsocks5Label == null)
			btn.dataset.hevsocks5Label = btn.textContent;
		btn.textContent = _('Working...');
		btn.disabled = true;
	}
	else {
		if (btn.dataset.hevsocks5Label != null) {
			btn.textContent = btn.dataset.hevsocks5Label;
			delete btn.dataset.hevsocks5Label;
		}
		btn.disabled = false;
	}
}

function notify(text, type) {
	var line = document.getElementById('hevsocks5-result');
	if (!line)
		return;

	line.textContent = text;
	line.className = (type === 'error') ? 'alert-danger' : 'alert-success';
}

return view.extend({
	render: function() {
		var m = new form.Map(CONF, _('HEV SOCKS5 Server'),
			_('Manage hev-socks5-server with procd, random credentials and the complete YAML option set.'));

		var status = m.section(form.TypedSection);
		status.anonymous = true;
		status.render = function() {
			function update(running) {
				var label = document.getElementById('hevsocks5-status');
				var start = document.getElementById('hevsocks5-start');
				var stop = document.getElementById('hevsocks5-stop');

				if (label) {
					label.textContent = running ? _('Running') : _('Not running');
					label.className = running ? 'alert-success' : 'alert-danger';
				}

				// 忙碌中的按钮由 setButtonBusy 控制，状态轮询不要覆盖它
				if (start && start.dataset.hevsocks5Label == null)
					start.disabled = !!running;
				if (stop && stop.dataset.hevsocks5Label == null)
					stop.disabled = !running;
			}

			function statusUnavailable() {
				var label = document.getElementById('hevsocks5-status');
				if (label) {
					label.textContent = _('Status unavailable');
					label.className = 'alert-danger';
				}
			}

			function action(cmd, label, btn) {
				setButtonBusy(btn, true);
				notify(_('Working...'), 'ok');

				return callCtl(cmd).then(function(res) {
					// A failed status refresh must not turn a successful action into a failure.
					return getStatus().then(update, function() {}).then(function() {
						setButtonBusy(btn, false);
						notify(_('%s succeeded').format(label), 'ok');
						return res;
					});
				}).catch(function(e) {
					setButtonBusy(btn, false);
					notify(_('%s failed').format(label), 'error');
					showError(e);
				});
			}

			// Keep a reference so the callback unregisters itself as soon as this
			// view is replaced; otherwise polling keeps hitting ubus forever.
			var statusPoll = function() {
				if (!document.getElementById('hevsocks5-status-section')) {
					poll.remove(statusPoll);
					return Promise.resolve();
				}

				return getStatus().then(update, statusUnavailable);
			};

			var section = E('div', { 'class': 'cbi-section', 'id': 'hevsocks5-status-section' }, [
				E('h3', {}, _('Service status')),
				E('p', {}, [
					_('Status') + ': ',
					E('span', { 'id': 'hevsocks5-status', 'aria-live': 'polite' }, _('Collecting data...'))
				]),
				E('p', { 'id': 'hevsocks5-result', 'class': 'alert-success', 'aria-live': 'polite' }, ''),
				E('div', { 'class': 'cbi-section-actions' }, [
					E('button', {
						'class': 'btn', 'id': 'hevsocks5-start', 'type': 'button',
						'click': function(ev) { return action('start', _('Start'), ev.currentTarget); }
					}, _('Start')),
					' ',
					E('button', {
						'class': 'btn', 'id': 'hevsocks5-stop', 'type': 'button',
						'click': function(ev) { return action('stop', _('Stop'), ev.currentTarget); }
					}, _('Stop')),
					' ',
					E('button', {
						'class': 'btn', 'type': 'button',
						'click': function(ev) { return action('restart', _('Restart'), ev.currentTarget); }
					}, _('Restart')),
					' ',
					E('button', {
						'class': 'btn', 'type': 'button',
						'click': function(ev) { return action('apply', _('Regenerate config and apply'), ev.currentTarget); }
					}, _('Regenerate config and apply'))
				])
			]);

			// poll.add() returns false when another poll is already active;
			// do not leave the status stuck on "Collecting data..." in that case.
			if (!poll.add(statusPoll)) {
				var label = section.querySelector('#hevsocks5-status');
				if (label) {
					label.textContent = _('Status unavailable');
					label.className = 'alert-danger';
				}
			}

			return section;
		};

		var s = m.section(form.NamedSection, 'config', CONF, _('Configuration'));
		s.addremove = false;
		s.anonymous = true;
		s.selected_tab = 'basic';

		s.tab('basic', _('Basic'));
		s.tab('listen', _('Advanced - Listen'));
		s.tab('route', _('Advanced - Routing'));
		s.tab('auth', _('Advanced - Authentication'));
		s.tab('misc', _('Advanced - Tuning and logs'));

		var o;

		o = s.taboption('basic', form.Flag, 'enabled', _('Enabled / start on boot'),
			_('Controls both the running instance and the procd boot link. Disable it to stop the server and remove autostart.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('basic', RandomValue, 'username', _('Username'),
			_('Single inline SOCKS5 user. Up to 255 characters. Ignored when an authentication file is configured. A random value is generated on first install.'));
		o.randLen = 16;
		o.default = '';
		o.rmempty = true;

		o = s.taboption('basic', PasswordValue, 'password', _('Password'),
			_('Up to 255 characters. Stored in plain text in UCI and in the generated YAML, so restrict file permissions accordingly.'));
		o.randLen = 24;
		o.default = '';
		o.rmempty = true;

		o = s.taboption('listen', form.Value, 'workers', _('Worker threads'),
			_('Number of worker threads handling SOCKS5 sessions. Each thread owns its own task system. On a small router 1-4 is usually enough.'));
		o.default = '4';
		o.datatype = 'uinteger';
		o.validate = function(section_id, value) {
			if (/^[0-9]+$/.test(value) && Number(value) >= 1)
				return true;

			return _('Worker threads must be at least 1');
		};
		o.rmempty = false;

		o = s.taboption('listen', form.Value, 'port', _('TCP listen port'),
			_('Port for the SOCKS5 CONNECT service. Remember to open it in the firewall.'));
		o.default = '1080';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('listen', form.Value, 'listen_address', _('Listen address'),
			_('IPv4 or IPv6 address to bind. The default :: accepts IPv4-mapped connections as well; use 0.0.0.0 for IPv4 only.'));
		o.default = '::';
		o.rmempty = false;

		o = s.taboption('listen', form.Value, 'udp_port', _('UDP listen port'),
			_('Leave empty or use 0 for one ephemeral UDP port per session. A fixed port uses the same port for every session; a-b picks a port from the range in round-robin order. Open the chosen port or range in the firewall.'));
		o.placeholder = '10000-20000';
		o.validate = function(section_id, value) {
			if (value === '')
				return true;

			var parts = /^([0-9]+)(?:-([0-9]+))?$/.exec(value);
			if (!parts)
				return _('Use a port, a range like 10000-20000, or leave empty');

			var beg = Number(parts[1]);
			var end = parts[2] != null ? Number(parts[2]) : beg;
			if (beg < 1 || beg > 65535 || end < 1 || end > 65535 || beg > end)
				return _('Use a port, a range like 10000-20000, or leave empty');

			return true;
		};
		o.rmempty = true;

		o = s.taboption('listen', form.Value, 'udp_listen_address', _('UDP listen address'),
			_('Address used by UDP ASSOCIATE. When empty, the local address of the clients TCP connection is reused.'));
		o.placeholder = '::1';
		o.rmempty = true;

		o = s.taboption('listen', form.Value, 'udp_public_address_v4', _('UDP public address (IPv4)'),
			_('IPv4 address reported to clients in the UDP ASSOCIATE reply. Set this when the server is behind NAT and the advertised address must differ from the bound address.'));
		o.placeholder = '203.0.113.1';
		o.rmempty = true;

		o = s.taboption('listen', form.Value, 'udp_public_address_v6', _('UDP public address (IPv6)'),
			_('Same as above for IPv6 clients.'));
		o.placeholder = '2001:db8::1';
		o.rmempty = true;

		o = s.taboption('listen', form.Flag, 'listen_ipv6_only', _('Listen IPv6 only'),
			_('Sets IPV6_V6ONLY on the listening socket. Enable it to reject IPv4-mapped connections.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('listen', form.Flag, 'tcp_fastopen', _('TCP fast open'),
			_('Enable TCP Fast Open on the listening socket. Requires kernel and client support; leave off unless you know both sides support it.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('route', form.Value, 'bind_address', _('Bind source address'),
			_('Source address for outbound connections, for both address families. Can be overridden by the IPv4/IPv6 specific settings below.'));
		o.placeholder = '192.168.1.2';
		o.rmempty = true;

		o = s.taboption('route', form.Value, 'bind_address_v4', _('Bind source address (IPv4)'),
			_('Source IPv4 address for outbound connections. Useful with multiple WAN addresses or policy routing.'));
		o.placeholder = '192.168.1.2';
		o.rmempty = true;

		o = s.taboption('route', form.Value, 'bind_address_v6', _('Bind source address (IPv6)'),
			_('Source IPv6 address for outbound connections.'));
		o.placeholder = '2001:db8::2';
		o.rmempty = true;

		o = s.taboption('route', form.Value, 'bind_interface', _('Bind source interface'),
			_('Forces outbound sessions to a network interface via SO_BINDTODEVICE, for example eth2 or wwan0. Leave empty to use the routing table.'));
		o.placeholder = 'eth2';
		o.rmempty = true;

		o = s.taboption('route', form.ListValue, 'domain_address_type', _('Domain address type'),
			_('Address family used when replying to domain name requests. unspec keeps the behaviour chosen by the resolver; ipv4 or ipv6 force one family.'));
		o.default = 'unspec';
		o.value('unspec', _('Unspecified'));
		o.value('ipv4', _('IPv4'));
		o.value('ipv6', _('IPv6'));

		o = s.taboption('route', form.Value, 'mark', _('Socket mark'),
			_('SO_MARK applied to outbound sessions. Accepts decimal, hexadecimal (0x1a) or octal (01) notation. Can be used with iptables connlimit or policy routing. A MARK column in the authentication file overrides this value for that user.'));
		o.default = '0';
		o.placeholder = '0x1a';
		o.validate = function(section_id, value) {
			if (value === '' || /^(0[xX][0-9A-Fa-f]+|[0-9]+)$/.test(value))
				return true;

			return _('Use decimal, 0x hexadecimal or octal notation');
		};
		o.rmempty = false;

		o = s.taboption('auth', form.Value, 'auth_file', _('Authentication file'),
			_('Path to an authentication file with one "USER PASS [MARK]" entry per line. When set, this file takes precedence over the username and password on the Basic tab. Send SIGUSR1 to reload it without restarting.'));
		o.placeholder = '/etc/hev-socks5-server/auth.txt';
		o.rmempty = true;

		o = s.taboption('auth', form.Flag, 'allow_no_auth', _('Allow unauthenticated access'),
			_('Danger: with no username, password or authentication file the server would be an open proxy. This flag is required to permit that state. Leave it off for normal use.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('misc', form.Value, 'task_stack_size', _('Task stack size (bytes)'),
			_('Stack size for each per-session coroutine. The upstream default is 8192 bytes. Lower values save memory but may overflow with complex requests.'));
		o.default = '8192';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('misc', form.Value, 'udp_recv_buffer_size', _('UDP receive buffer (bytes)'),
			_('SO_RCVBUF for UDP relay sockets. The upstream default is 524288 bytes. Increase for high bandwidth UDP traffic.'));
		o.default = '524288';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('misc', form.Value, 'udp_copy_buffer_nums', _('UDP copy buffers'),
			_('Number of 1500-byte buffers used by the UDP splice path. The upstream default is 10.'));
		o.default = '10';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('misc', form.Value, 'connect_timeout', _('TCP connect timeout (ms)'),
			_('Maximum time to wait for an outbound TCP connection. The upstream default is 10000 ms.'));
		o.default = '10000';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('misc', form.Value, 'tcp_read_write_timeout', _('TCP read/write timeout (ms)'),
			_('Idle timeout for established TCP sessions. The upstream default is 300000 ms.'));
		o.default = '300000';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('misc', form.Value, 'udp_read_write_timeout', _('UDP read/write timeout (ms)'),
			_('Idle timeout for UDP relay sessions. The upstream default is 60000 ms.'));
		o.default = '60000';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('misc', form.Value, 'read_write_timeout', _('Legacy read/write timeout (ms)'),
			_('Compatibility option from older upstream versions. When set, the TCP and UDP specific timeouts above are not written to YAML and this value applies to both. Usually leave it empty.'));
		o.placeholder = '60000';
		o.datatype = 'uinteger';
		o.rmempty = true;

		o = s.taboption('misc', form.Value, 'log_file', _('Log file'),
			_('Leave empty for null, which sends logs to stdout/stderr where procd forwards them to the system log. Set an absolute path to write to a file; note that log rotation is not handled by this package.'));
		o.placeholder = '/tmp/hev-socks5-server.log';
		o.rmempty = true;

		o = s.taboption('misc', form.ListValue, 'log_level', _('Log level'),
			_('debug is verbose, error is minimal. warn is the upstream default.'));
		o.default = 'warn';
		o.value('debug', _('Debug'));
		o.value('info', _('Info'));
		o.value('warn', _('Warning'));
		o.value('error', _('Error'));

		o = s.taboption('misc', form.Value, 'limit_nofile', _('File descriptor limit'),
			_('The binary calls setrlimit() with this value at startup. The upstream init script already asks procd for 1000000 descriptors, so keep this value aligned.'));
		o.default = '1000000';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('misc', form.Value, 'pid_file', _('PID file (ignored on OpenWrt)'),
			_('Upstream supports a pid-file that makes the process daemonize itself. This package never generates it under procd, because detaching would break process supervision. Displayed here for completeness only.'));
		o.placeholder = '/run/hev-socks5-server.pid';
		o.rmempty = true;
		o.readonly = true;

		return m.render();
	}
});
