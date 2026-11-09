#!/usr/bin/ucode
// render.uc - UCI (/etc/config/singbox_core) -> sing-box config.json
//
// 设计原则：
//   1. UCI 是唯一数据源，本脚本是纯函数式渲染，不做任何持久化
//   2. 引用不存在的规则集文件时跳过该规则并告警，而不是渲染出必然检查失败的配置
//   3. 配置格式固定按 sing-box 1.14 生成，与 Makefile 的 SB_VERSION 对齐
//
// 输出：/var/run/sing-box-core/config.json
// 调试：直接对该文件执行 `sing-box check -c` 即可

'use strict';

import { writefile, mkdir, stat } from 'fs';
import * as uci from 'uci';

const OUT_DIR     = '/var/run/sing-box-core';
const CACHE_DB    = '/etc/sing-box-core/cache.db';
const BIN         = '/usr/libexec/sing-box-core/sing-box';

const ctx = uci.cursor();

/* ---------------- 取值辅助 ---------------- */

function g(section, option, defval) {
	let v = ctx.get('singbox_core', section, option);
	return (v == null || v == '') ? defval : v;
}

function flag(section, option, defval) {
	return g(section, option, defval) == '1';
}

// UCI 里同一个选项可能是字符串（option），也可能是列表（list）。
// LuCI 用 DynamicList 写入时会变成 list，所以两种都要吃。
function split_list(section, option) {
	let v = ctx.get('singbox_core', section, option);

	if (v == null)
		return [];

	if (type(v) == 'array')
		return filter(map(v, function(x) { return trim(x); }),
		              function(x) { return length(x) > 0; });

	if (v == '')
		return [];

	return filter(map(split(v, ','), function(x) { return trim(x); }),
	              function(x) { return length(x) > 0; });
}

/* ---------------- 规则集登记 ---------------- */

// 规则集不随包分发，全部在运行时由 sing-box 自己从 SagerNet 官方源拉取。
// 下载结果会缓存进 experimental.cache_file，重启不会重复拉。
const RS_BASE = {
	geosite: 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/',
	geoip:   'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/'
};

let rs_needed = {};

function need_rs(category, kind) {
	kind = kind ?? 'geosite';
	let tag = kind + '-' + category;
	rs_needed[tag] = { kind: kind, file: tag + '.srs' };
	return tag;
}

function need_many(categories, kind) {
	let out = [];
	map(categories, function(c) {
		let t = need_rs(c, kind);
		if (t != null)
			push(out, t);
		return null;
	});
	return out;
}

function is_ip(s) {
	return match(s, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) != null || match(s, /:/) != null;
}

/* ---------------- 二进制检查 ---------------- */

// 只检查文件存在，不在这里探测版本。
// ucode 的 popen 在不同版本上行为不一致，取不到输出时会把「二进制正常」误判成
// 「二进制缺失」，直接把服务卡死。版本由 Makefile 的 SB_VERSION 固定为 1.14.0，
// 插件也只按 1.14 的配置格式生成，不需要运行时再判断一次。
if (stat(BIN) == null) {
	warn('未找到 sing-box 二进制：' + BIN + '\n');
	exit(1);
}

/* ---------------- 节点 ---------------- */

const protocol = g('node', 'protocol', 'hysteria2');
const server   = g('node', 'server', '');

if (server == '') {
	warn('节点地址为空，请先在 LuCI 里填写服务器\n');
	exit(1);
}

// 缺必填字段时提前退出，比让 sing-box 报一句难懂的 check 错误好
if (protocol == 'hysteria2' && g('node', 'password', '') == '') {
	warn('Hysteria2 需要填写密码\n');
	exit(1);
}

if (protocol == 'tuic' && g('node', 'uuid', '') == '') {
	warn('TUIC 需要填写 UUID\n');
	exit(1);
}

let tls_server_name = g('node', 'sni', '');
if (tls_server_name == '')
	tls_server_name = server;

let proxy = {
	type: protocol,
	tag: 'proxy',
	server: server,
	server_port: +g('node', 'server_port', '443'),
	tls: {
		enabled: true,
		server_name: tls_server_name,
		insecure: flag('node', 'insecure', '0')
	}
};

if (protocol == 'hysteria2') {
	let pw = g('node', 'password', '');
	if (pw != '')
		proxy.password = pw;

	let obfs = g('node', 'obfs', '');
	if (obfs != '')
		proxy.obfs = { type: 'salamander', password: g('node', 'obfs_password', '') };
}
else {
	proxy.uuid = g('node', 'uuid', '');
	let pw = g('node', 'password', '');
	if (pw != '')
		proxy.password = pw;
	proxy.congestion_control = g('node', 'congestion_control', 'bbr');
	proxy.udp_relay_mode     = g('node', 'udp_relay_mode', 'native');
}

/* ---------------- DNS ---------------- */

const bootstrap     = g('dns', 'bootstrap', '223.5.5.5');
const cn_server     = g('dns', 'cn_server', '223.5.5.5');
const cn_path       = g('dns', 'cn_path', '/dns-query');
const remote_server = g('dns', 'remote_server', 'dns.google');
const remote_path   = g('dns', 'remote_path', '/dns-query');

let dns_servers = [
	{ type: 'udp',   tag: 'bootstrap', server: bootstrap },
	{ type: 'https', tag: 'cn',        server: cn_server, path: cn_path }
];

let remote_srv = {
	type: 'https',
	tag: 'remote',
	server: remote_server,
	path: remote_path,
	detour: 'proxy'
};

// 域名形式的 DoH 端点需要 bootstrap 解析自身；IP 形式不需要，省一跳
let remote_is_ip = is_ip(remote_server);
if (!remote_is_ip)
	remote_srv.domain_resolver = 'bootstrap';

push(dns_servers, remote_srv);

let dns_rules = [];

// 显式远端分类优先，避免被 geosite-cn 误判成国内
let remote_cats = need_many(split_list('dns', 'remote_categories'), 'geosite');
if (length(remote_cats) > 0)
	push(dns_rules, { rule_set: remote_cats, server: 'remote' });

if (flag('route', 'bypass_cn', '1')) {
	let cn_rs = need_rs('cn', 'geosite');
	if (cn_rs != null)
		push(dns_rules, { rule_set: [cn_rs], server: 'cn' });
}

let dns_block = {
	servers: dns_servers,
	rules: dns_rules,
	final: 'remote',
	strategy: g('dns', 'strategy', 'prefer_ipv4')
};

let cache_capacity = +g('dns', 'cache_capacity', '4096');
// 小于 1024 会被 sing-box 静默忽略，等于没设
if (cache_capacity < 1024)
	cache_capacity = 4096;
dns_block.cache_capacity = cache_capacity;

// optimistic 需要 1.14+，包自带的内核满足
if (flag('dns', 'optimistic', '1'))
	dns_block.optimistic = true;

/* ---------------- TUN 入站 ---------------- */

let tun = {
	type: 'tun',
	tag: 'tun-in',
	interface_name: 'sbc-tun',
	address: [g('route', 'tun_address', '172.19.0.1/30')],
	mtu: +g('route', 'tun_mtu', '1400'),
	auto_route: true,
	strict_route: true,
	iproute2_table_index: +g('route', 'tun_table', '2023'),
	iproute2_rule_index: +g('route', 'tun_rule', '9100'),
	route_exclude_address: [
		'10.0.0.0/8',
		'172.16.0.0/12',
		'192.168.0.0/16',
		'127.0.0.0/8'
	]
};

// auto_redirect 需要 1.10+，包自带的内核满足
if (flag('route', 'auto_redirect', '1'))
	tun.auto_redirect = true;

/* ---------------- 路由规则 ---------------- */

let rules = [];

push(rules, { action: 'sniff' });

// dnsmasq / zerotier 等本机服务必须直连；放在 hijack-dns 之前才等价于 dae 的 must_direct
let bypass_procs = split_list('route', 'bypass_process');
if (length(bypass_procs) > 0)
	push(rules, {
		process_name: bypass_procs,
		action: 'route',
		outbound: 'direct'
	});

// 指定 DNS 进程的 53 端口不被劫持
let exempt_procs = split_list('route', 'dns_hijack_exempt_process');
if (length(exempt_procs) > 0)
	push(rules, {
		process_name: exempt_procs,
		network: 'udp',
		port: [53],
		action: 'route',
		outbound: 'direct'
	});

push(rules, { protocol: 'dns', action: 'hijack-dns' });

// 指定进程访问指定 IP 的 443 强制走代理（原规则第一条）
let forced_procs   = split_list('route', 'forced_proxy_process');
let forced_targets = split_list('route', 'forced_proxy_target');
if (length(forced_procs) > 0 && length(forced_targets) > 0) {
	let cidrs = map(forced_targets, function(x) {
		return x + (match(x, /:/) != null ? '/128' : '/32');
	});
	push(rules, {
		process_name: forced_procs,
		ip_cidr: cidrs,
		port: [443],
		action: 'route',
		outbound: 'proxy'
	});
}

if (flag('route', 'block_ads', '1')) {
	let ads = need_rs('category-ads-all', 'geosite');
	if (ads != null)
		push(rules, { rule_set: [ads], action: 'reject' });
}

// 阻断全部 QUIC，强制降级到 TCP。注意这条覆盖了任何按分类细分 QUIC 的写法。
if (flag('route', 'block_quic', '1'))
	push(rules, { network: 'udp', port: [443], action: 'reject' });

// 按源 MAC 强制走代理（需要 sing-box 1.14+ 与邻居解析）
let lan_mac = g('route', 'lan_mac', '');
if (lan_mac != '')
	push(rules, {
		source_mac_address: [lan_mac],
		action: 'route',
		outbound: 'proxy'
	});

if (flag('route', 'bypass_cn', '1')) {
	let geoip_cn = need_rs('cn', 'geoip');
	if (geoip_cn != null)
		push(rules, { rule_set: [geoip_cn], action: 'route', outbound: 'direct' });
}

// 组播与私网一律直连
push(rules, { ip_cidr: ['224.0.0.0/3'], action: 'route', outbound: 'direct' });
push(rules, { ip_is_private: true, action: 'route', outbound: 'direct' });

/* ---------------- 规则集列表 ---------------- */

let rule_sets = [];
let rs_tags = keys(rs_needed);

for (let i = 0; i < length(rs_tags); i++) {
	let tag = rs_tags[i];
	let e = rs_needed[tag];

	push(rule_sets, {
		type: 'remote',
		tag: tag,
		format: 'binary',
		// 官方文件名里 ! 必须编码，category-ai-!cn 是唯一会遇到的情况
		url: RS_BASE[e.kind] + replace(e.file, '!', '%21'),
		http_client: 'rs-download',
		update_interval: '7d'
	});
}

/* ---------------- 组装 ---------------- */

let cfg = {
	log: {
		level: g('main', 'log_level', 'info'),
		timestamp: true
	},
	// 1.14 起 rule-set 的下载出站走 http_client（download_detour 已弃用）。
	// 不能 detour 到「空的 direct 出站」，sing-box 会直接拒绝：
	//   detour to an empty direct outbound makes no sense
	// 除非 direct 显式配了 bind_interface。这里走 proxy：不依赖 wan 接口名，
	// 且节点可用时必然能下载。代价是节点配置错误时规则集也拉不到，
	// 服务会起不来 —— apply.sh 会把日志打出来，便于定位。
	http_clients: [
		{ tag: 'rs-download', detour: 'proxy' }
	],
	dns: dns_block,
	inbounds: [tun],
	outbounds: [
		proxy,
		{ type: 'direct', tag: 'direct' }
	],
	route: {
		auto_detect_interface: true,
		// 1.14 起必填：出站域名默认用 bootstrap 解析，否则 sing-box 拒绝启动。
		// 指向直连的明文 DNS，避免解析出站域名又要走代理的回环。
		default_domain_resolver: 'bootstrap',
		rule_set: rule_sets,
		rules: rules,
		final: 'proxy'
	},
	experimental: {
		cache_file: {
			enabled: true,
			path: CACHE_DB
		},
		clash_api: {
			external_controller: '127.0.0.1:9091'
		}
	}
};

// 1.14 起邻居解析要显式开，否则 source_mac_address 拿不到数据
if (lan_mac != '') {
	cfg.route.find_neighbor = true;
	let lease = g('route', 'dhcp_lease_file', '');
	if (lease != '')
		cfg.route.dhcp_lease_files = [lease];
}

// ucode 的 JSON 格式化是 %J，精度控制缩进：%.4J = 4 空格，%.J = tab
let out = sprintf('%.4J\n', cfg);

if (stat(OUT_DIR) == null)
	mkdir(OUT_DIR);
writefile(OUT_DIR + '/config.json', out);
