'use strict';
'require view';
'require rpc';
'require ui';

/*
 * OxiDNS Cache Lookup
 *
 * Read-only diagnostics page. All DNS data comes from the running OxiDNS
 * management API through rpcd (never directly from the browser), so no
 * credentials or management ports are exposed to clients.
 *
 * Layout:
 *   - search box with live cache autocomplete (down/up/enter)
 *   - upper pane: answer / TTL / route / split reason / hosting info
 *   - lower pane: per-upstream timing (triggered, 1-3s, async)
 *
 * IP geolocation is the only external call and is made by the *browser*
 * to ipwho.is (ipinfo.io fallback), mirroring photondns. Private / Fake-IP
 * addresses are never sent out.
 */

var callCacheSuggest = rpc.declare({
	object: 'luci.oxidns',
	method: 'cache_suggest',
	params: ['qname', 'limit'],
	expect: {}
});

var callCacheDetail = rpc.declare({
	object: 'luci.oxidns',
	method: 'cache_detail',
	params: ['qname'],
	expect: {}
});

var callUpstreams = rpc.declare({
	object: 'luci.oxidns',
	method: 'upstreams',
	params: ['group'],
	expect: {}
});

var callProbeUpstreams = rpc.declare({
	object: 'luci.oxidns',
	method: 'probe_upstreams',
	params: ['qname', 'group'],
	expect: {}
});

var callZoneInfo = rpc.declare({
	object: 'luci.oxidns',
	method: 'zone_info',
	params: ['qname'],
	expect: {}
});

var callTraceRoute = rpc.declare({
	object: 'luci.oxidns',
	method: 'trace_route',
	params: ['qname'],
	expect: {}
});

/* ------------------------------------------------------------------------- */
/* Static provider tables (translated from photondns src/hosting.rs).        */
/* rule starting with '.' = suffix match, otherwise substring match.         */
/* ------------------------------------------------------------------------- */
var DNS_PROVIDERS = [
	['.ns.cloudflare.com', 'Cloudflare'],
	['awsdns-', 'Amazon Route 53'],
	['.googledomains.com', 'Google Cloud DNS'],
	['.google.com', 'Google'],
	['azure-dns.', 'Azure DNS'],
	['.alidns.com', 'Alibaba Cloud DNS'],
	['.hichina.com', 'Alibaba Cloud DNS (HiChina)'],
	['.dnspod.net', 'DNSPod (Tencent Cloud)'],
	['.dnspod.com', 'DNSPod (Tencent Cloud)'],
	['.dnsv1.com', 'DNSPod (Tencent Cloud)'],
	['.dnsv2.com', 'DNSPod (Tencent Cloud)'],
	['.dnsv3.com', 'DNSPod (Tencent Cloud)'],
	['.dnsv4.com', 'DNSPod (Tencent Cloud)'],
	['.dnsv5.com', 'DNSPod (Tencent Cloud)'],
	['.qq.com', 'Tencent'],
	['huaweicloud-dns.', 'Huawei Cloud DNS'],
	['.bdydns.com', 'Baidu Cloud DNS'],
	['.baidu.com', 'Baidu'],
	['.jdcloud.com', 'JD Cloud DNS'],
	['.akam.net', 'Akamai Edge DNS'],
	['.nsone.net', 'NS1'],
	['ultradns.', 'UltraDNS'],
	['.dynect.net', 'Oracle Dyn'],
	['.domaincontrol.com', 'GoDaddy'],
	['.registrar-servers.com', 'Namecheap'],
	['.vercel-dns.com', 'Vercel'],
	['.digitalocean.com', 'DigitalOcean'],
	['.linode.com', 'Akamai (Linode)'],
	['.hetzner.com', 'Hetzner'],
	['.hetzner.de', 'Hetzner'],
	['.ovh.net', 'OVHcloud'],
	['.gandi.net', 'Gandi'],
	['.he.net', 'Hurricane Electric'],
	['.cloudns.net', 'ClouDNS'],
	['.name.com', 'Name.com'],
	['.dnsimple.com', 'DNSimple'],
	['.dnsimple-edge.net', 'DNSimple'],
	['.porkbun.com', 'Porkbun'],
	['.squarespacedns.com', 'Squarespace'],
	['.wixdns.net', 'Wix'],
	['.github.com', 'GitHub'],
	['.microsoftonline.com', 'Microsoft'],
	['.msft.net', 'Microsoft'],
	['.apple.com', 'Apple'],
	['.facebook.com', 'Meta']
];

var CDN_PROVIDERS = [
	['.cdn.cloudflare.net', 'Cloudflare'],
	['.cloudflare.net', 'Cloudflare'],
	['.cloudfront.net', 'Amazon CloudFront'],
	['.elb.amazonaws.com', 'AWS Elastic Load Balancing'],
	['.amazonaws.com', 'Amazon Web Services'],
	['.akamaiedge.net', 'Akamai'],
	['.akamai.net', 'Akamai'],
	['.edgekey.net', 'Akamai'],
	['.edgesuite.net', 'Akamai'],
	['.akamaized.net', 'Akamai'],
	['.akadns.net', 'Akamai'],
	['.fastly.net', 'Fastly'],
	['.fastlylb.net', 'Fastly'],
	['.azureedge.net', 'Azure CDN'],
	['.azurefd.net', 'Azure Front Door'],
	['.trafficmanager.net', 'Azure Traffic Manager'],
	['.azurewebsites.net', 'Azure App Service'],
	['.ghs.googlehosted.com', 'Google'],
	['.googlehosted.com', 'Google'],
	['.l.google.com', 'Google'],
	['.kunlun', 'Alibaba Cloud CDN'],
	['.alikunlun.com', 'Alibaba Cloud CDN'],
	['.alicdn.com', 'Alibaba Cloud CDN'],
	['.tbcache.com', 'Alibaba Cloud CDN'],
	['.aliyuncs.com', 'Alibaba Cloud'],
	['.cdn.dnsv1.com', 'Tencent Cloud CDN'],
	['.cdntip.com', 'Tencent Cloud CDN'],
	['.tencent-cloud.net', 'Tencent Cloud'],
	['.shifen.com', 'Baidu'],
	['.bilicdn1.com', 'Bilibili CDN'],
	['.eo.dnse0.com', 'Tencent EdgeOne'],
	['.eo.dnse1.com', 'Tencent EdgeOne'],
	['.eo.dnse2.com', 'Tencent EdgeOne'],
	['.eo.dnse3.com', 'Tencent EdgeOne'],
	['.eo.dnse4.com', 'Tencent EdgeOne'],
	['.eo.dnse5.com', 'Tencent EdgeOne'],
	['.jcloud-cdn.com', 'JD Cloud CDN'],
	['.bcebos.com', 'Baidu Cloud'],
	['.wscdns.com', 'Wangsu (ChinaNetCenter)'],
	['.wswebcdn.com', 'Wangsu (ChinaNetCenter)'],
	['.lxdns.com', 'Wangsu (ChinaNetCenter)'],
	['.cdn20.com', 'Wangsu (ChinaNetCenter)'],
	['.chinacache.net', 'ChinaCache'],
	['.vercel-dns.com', 'Vercel'],
	['.vercel.app', 'Vercel'],
	['.netlify.app', 'Netlify'],
	['.netlifyglobalcdn.com', 'Netlify'],
	['.github.io', 'GitHub Pages'],
	['.githubusercontent.com', 'GitHub'],
	['.edgecastcdn.net', 'Edgio'],
	['.cdn77.org', 'CDN77'],
	['.b-cdn.net', 'Bunny CDN'],
	['.herokudns.com', 'Heroku'],
	['.shopify.com', 'Shopify'],
	['.myshopify.com', 'Shopify'],
	['.squarespace.com', 'Squarespace'],
	['.wordpress.com', 'WordPress.com']
];

/* Cloudflare published IPv4 ranges (cloudflare.com/ips) - base/prefix pairs. */
var CLOUDFLARE_V4 = [
	[0xADF53000, 20], [0x6715F400, 22], [0x6716C800, 22], [0x671F0400, 22],
	[0x8D654000, 18], [0x6CA2C000, 18], [0xBE5DF000, 20], [0xBC726000, 20],
	[0xC5EAF000, 22], [0xC6298000, 17], [0xA29E0000, 15], [0x68100000, 13],
	[0x68180000, 14], [0xAC400000, 13], [0x83004800, 22]
];

/* msg -> split-category label (from v9 query_summary outlets). */
var MSG_LABELS = {
	'本地应答': '本地应答',
	'内网组': '内网组',
	'国外请求': '国外请求',
	'国外请求·强制名单命中': '国外请求 · 强制名单命中',
	'出口转内销': '出口转内销（国外解析得中国 IP，已转国内重查）',
	'国内请求·geosite命中': '国内请求 · geosite 命中',
	'国内请求·域名列表命中': '国内请求 · 域名列表命中',
	'国内请求·强制名单命中': '国内请求 · 强制名单命中',
	'国内缓存': '国内缓存命中',
	'国外缓存': '国外缓存命中',
	'内网缓存': '内网缓存命中',
	'安全拦截': '安全黑名单拦截',
	'拦截': '广告拦截',
	'缓存命中': '缓存命中',
	'国内组': '国内组',
	'国外组': '国外组'
};

var state = {
	suggestions: [],
	sel: -1,
	qname: '',
	loading: false,
	group: 'cn',
	tracedGroup: '',   // group resolved by the bypass-cache probe
	traceInfo: null,   // last trace_route result
	geoCache: {},
	geoPending: {}
};

var suggestTimer = null;
var currentDetail = null;

function byId(id) { return document.getElementById(id); }

function tableLookup(name, table) {
	if (!name) return null;
	name = String(name).replace(/\.$/, '').toLowerCase();
	for (var i = 0; i < table.length; i++) {
		var rule = table[i][0];
		var hit;
		if (rule.charAt(0) === '.')
			hit = (name === rule.slice(1) || name.slice(-rule.length) === rule);
		else
			hit = name.indexOf(rule) >= 0;
		if (hit) return table[i][1];
	}
	return null;
}

function dnsProvider(zone, nameservers) {
	var out = [];
	for (var i = 0; i < nameservers.length; i++) {
		var ns = nameservers[i];
		var prov = tableLookup(ns, DNS_PROVIDERS);
		if (!prov && zone && ns.slice(-(zone.length + 1)) === '.' + zone)
			prov = 'self-hosted';
		if (prov && out.indexOf(prov) < 0) out.push(prov);
	}
	return out.join(' + ');
}

function cdnProvider(cnameTargets) {
	for (var i = cnameTargets.length - 1; i >= 0; i--) {
		var prov = tableLookup(cnameTargets[i], CDN_PROVIDERS);
		if (prov) return prov;
	}
	return null;
}

function ipv4ToInt(ip) {
	var p = ip.split('.');
	if (p.length !== 4) return null;
	return (((parseInt(p[0], 10) << 24) >>> 0) + (parseInt(p[1], 10) << 16) +
		(parseInt(p[2], 10) << 8) + parseInt(p[3], 10)) >>> 0;
}

function isCloudflareIP(ip) {
	var v = ipv4ToInt(ip);
	if (v === null) return false;
	for (var i = 0; i < CLOUDFLARE_V4.length; i++) {
		var base = CLOUDFLARE_V4[i][0], len = CLOUDFLARE_V4[i][1];
		var mask = len === 0 ? 0 : ((0xFFFFFFFF << (32 - len)) >>> 0);
		if (((v & mask) >>> 0) === ((base & mask) >>> 0)) return true;
	}
	return false;
}

function isPrivateIP(ip) {
	return /^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|0\.|::1$|fc00:|fe80:|198\.18\.)/.test(ip);
}

/* Try to extract a hostname from pasted URLs; otherwise return trimmed input. */
function extractHostname(raw) {
	var s = String(raw || '').trim();
	if (!s) return '';
	if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(s)) {
		try { return new URL(s).hostname; } catch (e) { /* fall through */ }
	}
	var m = s.match(/(?:https?:\/\/)?([a-zA-Z0-9._-]+(?:\.[a-zA-Z]{2,}))(?:$|[\/:?#])/);
	return m ? m[1] : s;
}

function parseJsonField(v) {
	if (v === null || v === undefined || v === '') return null;
	if (typeof v === 'object') return v;
	try { return JSON.parse(v); } catch (e) { return null; }
}

/* ---------------------------- autocomplete ------------------------------ */
function onInput(ev) {
	var val = byId('oxidns-cache-input').value;
	if (suggestTimer) window.clearTimeout(suggestTimer);
	suggestTimer = window.setTimeout(function() {
		return callCacheSuggest(val, 15).then(function(res) {
			var body = parseJsonField(res && res.entries);
			var entries = (body && body.entries) ? body.entries : [];
			state.suggestions = entries.slice(0, 15);
			state.sel = -1;
			renderSuggestions();
		}).catch(function() {
			state.suggestions = [];
			renderSuggestions();
		});
	}, 220);
}

function renderSuggestions() {
	var box = byId('oxidns-cache-suggest');
	if (!box) return;
	var list = state.suggestions;
	if (!list.length) { box.style.display = 'none'; box.innerHTML = ''; return; }
	var html = '<div class="oxidns-suggest-item" data-i="-2" style="padding:.35em .6em;color:#888;font-size:12px;'
		+ 'border-bottom:1px solid #ddd;">' + _('Cached domains (up to 15)') + '</div>';
	for (var i = 0; i < list.length; i++) {
		var e = list[i];
		var name = e.domain || '';
		var type = e.record_type || 'A';
		var ttl = e.remaining_ttl;
		var cls = (i === state.sel) ? ' oxidns-suggest-active' : '';
		html += '<div class="oxidns-suggest-item' + cls + '" data-i="' + i + '" '
			+ 'style="padding:.4em .6em;cursor:pointer;display:flex;justify-content:space-between;gap:1em;">'
			+ '<span>' + escapeHtml(name) + '</span>'
			+ '<span style="color:#888;font-size:12px;white-space:nowrap;">' + escapeHtml(type)
			+ (ttl !== undefined ? ' · ' + ttl + 's' : '') + '</span></div>';
	}
	box.innerHTML = html;
	box.style.display = 'block';
	var items = box.querySelectorAll('.oxidns-suggest-item[data-i]');
	for (var j = 0; j < items.length; j++) {
		items[j].onclick = (function(idx) {
			return function() { chooseSuggestion(idx); };
		})(parseInt(items[j].getAttribute('data-i'), 10));
	}
}

function escapeHtml(s) {
	return String(s === null || s === undefined ? '' : s)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function chooseSuggestion(idx) {
	if (idx < 0 || idx >= state.suggestions.length) return;
	var e = state.suggestions[idx];
	var name = e.domain || '';
	byId('oxidns-cache-input').value = name;
	byId('oxidns-cache-suggest').style.display = 'none';
	resolveName(name);
}

function onKeyDown(ev) {
	var box = byId('oxidns-cache-suggest');
	if (ev.key === 'ArrowDown') {
		ev.preventDefault();
		if (state.suggestions.length) {
			state.sel = (state.sel + 1) % state.suggestions.length;
			renderSuggestions();
		}
	} else if (ev.key === 'ArrowUp') {
		ev.preventDefault();
		if (state.suggestions.length) {
			state.sel = (state.sel - 1 + state.suggestions.length) % state.suggestions.length;
			renderSuggestions();
		}
	} else if (ev.key === 'Enter') {
		ev.preventDefault();
		if (state.sel >= 0 && state.suggestions[state.sel])
			chooseSuggestion(state.sel);
		else {
			if (box) box.style.display = 'none';
			resolveName(extractHostname(byId('oxidns-cache-input').value));
		}
	} else if (ev.key === 'Escape') {
		if (box) box.style.display = 'none';
	}
}

/* ------------------------------ resolve --------------------------------- */
function resolveName(qname) {
	if (!qname) return;
	state.qname = qname;
	byId('oxidns-cache-input').value = qname;
	byId('oxidns-cache-suggest').style.display = 'none';
	byId('oxidns-detail-body').innerHTML = '<p style="color:#888;">' + _('Resolving...') + '</p>';
	byId('oxidns-upstream-body').innerHTML = '';
	currentDetail = null;

	return callCacheDetail(qname).then(function(res) {
		// rpcd reports per-API failures via cache_ok/records_ok. When the
		// management API rejects auth (empty api_pass) the body is empty and
		// would otherwise be parsed as "0 entries" with no error shown.
		if (!res || res.ok === false || res.cache_ok === 0) {
			var why = (res && res.message) ? ': ' + String(res.message) : '';
			byId('oxidns-detail-body').innerHTML = '<p style="color:#c00;">'
				+ _('Failed to query OxiDNS API. Check that the service is running and api_pass is set.')
				+ escapeHtml(why) + '</p>';
			return;
		}
		var cache = parseJsonField(res && res.cache) || {};
		var records = parseJsonField(res && res.records) || {};
		var entries = cache.entries || [];
		var recs = records.records || records.result || [];
		currentDetail = { entries: entries, records: recs };
		renderDetail(qname, entries, recs);
		return loadHosting(qname, entries);
	}).catch(function(e) {
		byId('oxidns-detail-body').innerHTML = '<p style="color:#c00;">'
			+ _('Failed to query OxiDNS API. Check that the service is running and api_pass is set.')
			+ '</p>';
	}).then(function() {
		// Every resolve also performs a bypass-cache route probe so the
		// "split reason" and upstream group reflect the real route right now.
		return runTrace(qname);
	});
}

/* Bypass-cache probe: delete this name from cache, issue one real query and
 * read the recorder execution path. Updates the split-reason row and drives
 * the upstream group automatically. */
function runTrace(qname) {
	state.tracedGroup = '';
	return callTraceRoute(qname).then(function(tr) {
		state.traceInfo = tr || null;
		var reason = byId('oxidns-split-reason');
		if (tr && tr.ok !== false) {
			var grp = tr.group || '';
			state.tracedGroup = (grp === 'cn' || grp === 'abroad') ? grp : '';
			var path = tr.path || tr.outlet || _('Default routing (no explicit split outlet recorded)');
			var grpLabel = grp === 'cn' ? _('Domestic') : grp === 'abroad' ? _('International')
				: grp === 'privacy' ? _('Privacy') : grp === 'internal' ? _('Internal') : grp;
			var badge = grp ? (' <span class="oxidns-route-badge">' + escapeHtml(grpLabel) + '</span>') : '';
			if (reason) reason.innerHTML = escapeHtml(path) + badge;
			var grpEl = byId('oxidns-trace-group');
			if (grpEl && grp) grpEl.textContent = grpLabel;
			// Upstream timing follows the probed route automatically.
			if (state.tracedGroup) {
				state.group = state.tracedGroup;
				renderUpstreamsStatic();
				return runProbe();
			}
			return renderUpstreamsStatic();
		}
		if (reason) reason.innerHTML = escapeHtml(_('Route probe failed.'));
		return renderUpstreamsStatic();
	}).catch(function() {
		var reason = byId('oxidns-split-reason');
		if (reason) reason.innerHTML = escapeHtml(_('Route probe failed.'));
		return renderUpstreamsStatic();
	});
}

function pickEntry(entries, qname) {
	var q = String(qname).replace(/\.$/, '').toLowerCase();
	var exact = null, fallback = null;
	for (var i = 0; i < entries.length; i++) {
		var d = String(entries[i].domain || '').replace(/\.$/, '').toLowerCase();
		if (d === q && String(entries[i].record_type || 'A') === 'A') exact = entries[i];
		if (!fallback && d === q) fallback = entries[i];
	}
	return exact || fallback || entries[0] || null;
}

function answersOf(entry) {
	if (!entry) return [];
	var a = entry.answers_json;
	if (typeof a === 'string') { try { a = JSON.parse(a); } catch (e) { return []; } }
	return Array.isArray(a) ? a : [];
}

/* OxiDNS core serialises each answer as {rr_type, payload_text, payload:{...}}.
 * Older builds used address/data/ip/target at the top level. Read both so the
 * page works across core versions; this is why the IP list was empty before. */
function answerValue(a) {
	if (!a) return '';
	if (a.payload && typeof a.payload === 'object') {
		if (a.payload.ip) return String(a.payload.ip);
		if (a.payload.target) return String(a.payload.target);
		if (a.payload.exchange) return String(a.payload.exchange);
	}
	if (a.address || a.data || a.ip || a.target) return String(a.address || a.data || a.ip || a.target);
	if (a.payload_text) return String(a.payload_text);
	return '';
}
function answerType(a) {
	return String((a && (a.rr_type || a.type)) || '').toUpperCase();
}

function splitReason(recs) {
	// recorder steps record executor tags; find the first log_* outlet tag.
	var steps = [];
	for (var i = 0; i < recs.length; i++) {
		var s = recs[i].steps;
		if (typeof s === 'string') { try { s = JSON.parse(s); } catch (e) { s = []; } }
		if (Array.isArray(s)) steps = steps.concat(s);
	}
	for (var j = 0; j < steps.length; j++) {
		var st = steps[j];
		var tag = st.tag || st.executor || st.name || '';
		if (typeof tag === 'string' && /^log_/.test(tag)) {
			// try derive msg from tag, else map known tags
			var msg = st.msg || '';
			return MSG_LABELS[msg] || MSG_LABELS[tag] || tag;
		}
	}
	return _('Default routing (no explicit split outlet recorded)');
}

function kvRow(k, v) {
	return '<tr><td style="width:10em;color:#666;vertical-align:top;">' + escapeHtml(k)
		+ '</td><td>' + (v || '') + '</td></tr>';
}

function renderDetail(qname, entries, recs) {
	var entry = pickEntry(entries, qname);
	var answers = answersOf(entry);
	var ips = [];
	var cnames = [];
	for (var i = 0; i < answers.length; i++) {
		var a = answers[i];
		var t = answerType(a);
		var v = answerValue(a);
		if (!v) continue;
		if (t === 'A' || t === 'AAAA') ips.push(v);
		if (t === 'CNAME' || t === 'ANAME') cnames.push(v);
	}

	var html = '<table class="table cbi-section-table" style="border:0;"><tbody>';
	html += kvRow(_('Name'), '<strong>' + escapeHtml(qname) + '</strong>');
	html += kvRow(_('Answers'), ips.length
		? ips.map(function(ip) { return '<span data-ip="' + escapeHtml(ip) + '" class="oxidns-ip">'
			+ escapeHtml(ip) + ' <span class="oxidns-geo" style="color:#888;font-size:12px;">…</span></span>'; }).join('<br>')
		: '<span style="color:#888;">' + _('No cached A/AAAA answer') + '</span>');
	if (entry) {
		var ttl = entry.remaining_ttl !== undefined ? entry.remaining_ttl : entry.ttl;
		html += kvRow(_('TTL / Route'), escapeHtml(String(ttl)) + ' s · cache');
	} else {
		html += kvRow(_('TTL / Route'), '-');
	}
	html += kvRow(_('Split reason'), '<span id="oxidns-split-reason">'
		+ '<span style="color:#888;">' + _('Probing live route (bypassing cache)...') + '</span></span>');
	html += '</tbody></table>';
	byId('oxidns-detail-body').innerHTML = html;

	// async geolocation for each answer IP (browser-side, private IPs excluded)
	for (var k = 0; k < ips.length; k++) fillGeo(ips[k]);

	// hosting info placeholder; filled by loadHosting
	byId('oxidns-hosting-body').innerHTML = '<p style="color:#888;">' + _('Loading hosting info...') + '</p>';
	return cnames;
}

function fillGeo(ip) {
	if (isPrivateIP(ip)) {
		markGeo(ip, _('Private / internal address'));
		return;
	}
	if (state.geoCache[ip]) { markGeo(ip, state.geoCache[ip]); return; }
	if (state.geoPending[ip]) return;
	state.geoPending[ip] = true;
	fetch('https://ipwho.is/' + encodeURIComponent(ip))
		.then(function(r) { return r.json(); })
		.then(function(d) {
			var txt = d && d.success ? ((d.flag || '') + ' ' + (d.country || ''))
				: (d && d.message ? d.message : '?');
			state.geoCache[ip] = txt;
			markGeo(ip, txt);
		})
		.catch(function() {
			return fetch('https://ipinfo.io/' + encodeURIComponent(ip) + '/json')
				.then(function(r) { return r.json(); })
				.then(function(d) {
					var txt = d && d.country ? (d.country + (d.city ? ' / ' + d.city : '')) : '?';
					state.geoCache[ip] = txt;
					markGeo(ip, txt);
				}).catch(function() { markGeo(ip, ''); });
		});
}

function markGeo(ip, txt) {
	var spans = document.querySelectorAll('.oxidns-ip[data-ip]');
	for (var i = 0; i < spans.length; i++) {
		if (spans[i].getAttribute('data-ip') === ip) {
			var g = spans[i].querySelector('.oxidns-geo');
			if (g) g.textContent = txt ? '[' + txt + ']' : '';
		}
	}
}

function loadHosting(qname, entries) {
	var entry = pickEntry(entries, qname);
	var answers = answersOf(entry);
	var cnames = [];
	var answerIPs = [];
	for (var i = 0; i < answers.length; i++) {
		var a = answers[i];
		var t = answerType(a);
		var v = answerValue(a);
		if (!v) continue;
		if (t === 'CNAME' || t === 'ANAME') cnames.push(v);
		if (t === 'A' || t === 'AAAA') answerIPs.push(v);
	}
	var cdn = cdnProvider(cnames);
	var cfByIP = false;
	for (var k = 0; k < answerIPs.length; k++) { if (isCloudflareIP(answerIPs[k])) { cfByIP = true; break; } }

	return callZoneInfo(qname).then(function(res) {
		var zone = res && res.zone ? res.zone : '';
		var ns = (res && res.nameservers) ? res.nameservers : [];
		var provider = dnsProvider(zone, ns);
		var html = '<table class="table cbi-section-table" style="border:0;"><tbody>';
		html += kvRow(_('DNS provider'), provider ? escapeHtml(provider) : '<span style="color:#888;">' + _('Not detected') + '</span>');
		html += kvRow(_('Authoritative NS'), ns.length
			? ns.map(escapeHtml).join(' · ')
			: '<span style="color:#888;">' + _('Not available') + '</span>');
		if (cnames.length)
			html += kvRow(_('CNAME chain'), cnames.map(function(c) { return '<span style="color:#c00;">' + escapeHtml(c) + '</span>'; }).join(' &rarr; '));
		var cdnText = cdn || (cfByIP ? 'Cloudflare (proxied, detected by IP range)' : '');
		html += kvRow(_('CDN / hosting'), cdnText ? escapeHtml(cdnText) : '<span style="color:#888;">' + _('Not detected') + '</span>');
		html += '</tbody></table>';
		byId('oxidns-hosting-body').innerHTML = html;
	}).catch(function() {
		byId('oxidns-hosting-body').innerHTML = '<p style="color:#c00;">' + _('Failed to query NS info.') + '</p>';
	});
}

/* -------------------------- upstream timing ----------------------------- */
var upstreamCache = { cn: [], abroad: [] };

function renderUpstreamsStatic() {
	// Timing now follows the probed route automatically; only show a hint
	// before any probe result exists.
	if (!state.qname) {
		byId('oxidns-upstream-body').innerHTML = '<p style="color:#888;">'
			+ _('Resolve a domain to load upstream timing.') + '</p>';
		return Promise.resolve();
	}
	return Promise.resolve();
}

function runProbe() {
	if (!state.qname) { ui.showModal(_('Cache Lookup'), E('p', {}, _('Enter a domain first.'))); return Promise.resolve(); }
	byId('oxidns-probe-status').textContent = _('Testing %s upstreams (1-3s)...').format(
		state.group === 'abroad' ? _('International') : _('Domestic'));
	return callProbeUpstreams(state.qname, state.group).then(function(res) {
		var results = (res && res.results) ? res.results : [];
		var html = '<table class="table cbi-section-table" style="border:0;"><thead><tr>'
			+ '<th>' + _('Upstream') + '</th><th>' + _('Time') + '</th>'
			+ '<th>' + _('RCODE') + '</th><th>' + _('Answers') + '</th><th>' + _('Verdict') + '</th>'
			+ '</tr></thead><tbody>';
		var fastest = null;
		for (var i = 0; i < results.length; i++) {
			var lat = parseFloat(results[i].latency_ms);
			if (!isNaN(lat) && (fastest === null || lat < fastest)) fastest = lat;
		}
		for (var j = 0; j < results.length; j++) {
			var r = results[j];
			var lat2 = parseFloat(r.latency_ms);
			var latTxt = isNaN(lat2) ? '-' : (lat2.toFixed(1) + ' ms');
			var isFast = (!isNaN(lat2) && fastest !== null && Math.abs(lat2 - fastest) < 0.05);
			html += '<tr><td>' + escapeHtml(r.tag || '') + (isFast ? ' <span class="oxidns-fastest">' + _('fastest') + '</span>' : '')
				+ '</td><td>' + latTxt
				+ '</td><td>' + escapeHtml(r.rcode || '-') + '</td><td>' + escapeHtml(String(r.answer_count !== undefined && r.answer_count !== '' ? r.answer_count : '-'))
				+ '</td><td>' + escapeHtml(r.verdict || '-') + '</td></tr>';
		}
		if (!results.length) html += '<tr><td colspan="5" style="color:#888;">' + _('No results.') + '</td></tr>';
		html += '</tbody></table>';
		byId('oxidns-upstream-body').innerHTML = html;
		byId('oxidns-probe-status').textContent = _('Tested %s upstream(s).').format(results.length);
	}).catch(function() {
		byId('oxidns-probe-status').textContent = _('Probe failed.');
	});
}

return view.extend({
	load: function() { return Promise.resolve({}); },

	render: function() {
		// One-time inline stylesheet for the polished card layout. Scoped to
		// ids/classes unique to this view so other LuCI pages are unaffected.
		var style = E('style', {}, [
			'.oxidns-card{border:1px solid var(--border-color,#d4d7dc);border-radius:12px;'
				+ 'background:var(--box-background-color,#fff);padding:16px 18px;'
				+ 'margin-bottom:16px;box-shadow:0 1px 3px rgba(0,0,0,.05);}',
			'.oxidns-card h3{margin:0 0 12px;font-size:15px;font-weight:600;}',
			'.oxidns-route-badge{display:inline-block;margin-left:6px;padding:1px 8px;'
				+ 'border-radius:10px;background:#e7f1ff;color:#1a5fb4;font-size:12px;}',
			'.oxidns-fastest{display:inline-block;margin-left:4px;padding:0 6px;'
				+ 'border-radius:8px;background:#c0392b;color:#fff;font-size:11px;}',
			'.oxidns-card table.cbi-section-table{width:100%;}',
			'.oxidns-card table.cbi-section-table td,.oxidns-card table.cbi-section-table th{'
				+ 'padding:5px 4px;border-bottom:1px solid var(--border-color,#eee);}',
			'.oxidns-card table.cbi-section-table tr:last-child td{border-bottom:0;}',
			'.oxidns-card table.cbi-section-table th{font-size:12px;color:#888;font-weight:600;text-align:left;}'
		].join('\n'));

		var card = function(title, body, extraStyle) {
			return E('div', { 'class': 'oxidns-card', 'style': extraStyle || '' }, [
				E('h3', {}, title),
				body
			]);
		};

		return E('div', { 'class': 'cbi-map' }, [
			style,
			E('h2', {}, _('Cache Lookup')),
			E('div', { 'class': 'cbi-map-descr', 'style': 'margin-bottom:16px;' },
				_('Search the live OxiDNS cache and inspect answers, split routing, hosting info and upstream timing. Paste a URL to extract its hostname.')),

			// Domain search card
			card(_('Domain'), E('div', {}, [
				E('div', { 'style': 'position:relative;max-width:42em;' }, [
					E('input', {
						'id': 'oxidns-cache-input',
						'type': 'text',
						'class': 'cbi-input-text',
						'style': 'width:100%;box-sizing:border-box;border-radius:8px;',
						'placeholder': _('Type a domain or paste a URL...'),
						'autocomplete': 'off',
						'input': onInput,
						'keydown': onKeyDown
					}),
					E('div', {
						'id': 'oxidns-cache-suggest',
						'style': 'display:none;position:absolute;left:0;right:0;top:100%;z-index:20;background:#fff;'
							+ 'border:1px solid #d4d7dc;border-radius:8px;box-shadow:0 4px 12px rgba(0,0,0,.12);max-height:22em;overflow:auto;'
					}, '')
				]),
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'style': 'margin-top:.6em;border-radius:8px;',
					'click': function(ev) {
						ev.preventDefault();
						resolveName(extractHostname(byId('oxidns-cache-input').value));
					}
				}, _('Resolve')),
				E('span', { 'id': 'oxidns-probe-hint', 'style': 'color:#888;font-size:12px;margin-left:.75em;' },
					_('Resolving also runs a bypass-cache route probe.'))
			])),

			// Answer & routing card
			card(_('Answer & routing'), E('div', { 'id': 'oxidns-detail-body' },
				E('p', { 'style': 'color:#888;' }, _('Enter a domain to see cached answers and routing.')))),

			// Hosting info card
			card(_('Hosting info'), E('div', { 'id': 'oxidns-hosting-body' }, '')),

			// Upstream timing card
			card(_('Upstream timing'), E('div', {}, [
				E('div', { 'style': 'display:flex;gap:.75em;align-items:center;flex-wrap:wrap;margin-bottom:.6em;' }, [
					E('span', { 'style': 'color:#666;font-size:13px;' }, _('Route group') + ': '),
					E('span', { 'id': 'oxidns-trace-group', 'class': 'oxidns-route-badge',
						'style': 'margin-left:0;' }, _('Auto (from probe)')),
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'style': 'border-radius:8px;',
						'click': function(ev) { ev.preventDefault(); return runProbe(); }
					}, _('Retest upstreams')),
					E('span', { 'id': 'oxidns-probe-status', 'style': 'color:#888;font-size:12px;' }, '')
				]),
				E('p', { 'style': 'color:#888;font-size:12px;margin:0 0 8px;' },
					_('Upstreams follow the route detected by the bypass-cache probe; timing bypasses cache without affecting health stats.')),
				E('div', { 'id': 'oxidns-upstream-body' },
					E('p', { 'style': 'color:#888;' }, _('Resolve a domain to load upstream timing.')))
			]))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
