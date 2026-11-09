#!/bin/sh
# apply.sh - 安全地应用配置：渲染 -> 校验 -> 重启 -> 存活探测 -> 失败回滚
#
# 这是整个插件最重要的一个脚本。核心保证：
#   新配置只要有任何问题，旧配置会被原样恢复，网络不会断。
#
# 退出码：
#   0  成功
#   2  渲染失败（UCI 数据不完整）
#   3  配置校验失败（sing-box check）
#   4  启动后进程未存活（已回滚）

set -u

SB=/usr/libexec/sing-box-core/sing-box
RUN=/var/run/sing-box-core
CFG=$RUN/config.json
BAK=$RUN/config.json.bak
LOG=/var/log/sing-box-core-check.log
LOCK=/var/lock/sing-box-core-apply.lock

exec 9>"$LOCK"
flock -w 30 9 || { echo "另一个 apply 正在运行" >&2; exit 1; }

mkdir -p "$RUN" /etc/sing-box-core

# 保留上一份可用配置，用于回滚
[ -f "$CFG" ] && cp "$CFG" "$BAK"

# 1) 渲染
if ! /usr/libexec/sing-box-core/render.uc; then
	echo "配置渲染失败：请检查节点地址等必填项" >&2
	[ -f "$BAK" ] && cp "$BAK" "$CFG"
	exit 2
fi

# 2) 静态校验
if ! "$SB" check -c "$CFG" >"$LOG" 2>&1; then
	echo "配置校验失败：" >&2
	cat "$LOG" >&2
	if [ -f "$BAK" ]; then
		cp "$BAK" "$CFG"
	else
		rm -f "$CFG"
	fi
	exit 3
fi

# 3) 已关闭时只停服务，不能做存活探测
#    否则「有意关闭」会被判成「启动失败」，接着回滚配置，白折腾一轮
if [ "$(uci -q get singbox_core.main.enabled)" != "1" ]; then
	/etc/init.d/sing-box-core stop >/dev/null 2>&1
	echo "配置已保存。服务处于关闭状态，未启动。"
	exit 0
fi

# 4) 重启并探测存活
/etc/init.d/sing-box-core restart >/dev/null 2>&1
sleep 3

if ! pgrep -f "$SB run" >/dev/null 2>&1; then
	echo "sing-box 启动后未存活，已回滚到上一份配置" >&2
	# 最常见的原因是规则集拉取失败（首次启动必须联网下载）
	echo "--- 最近日志 ---" >&2
	logread -e sing-box-core 2>/dev/null | tail -8 >&2
	if [ -f "$BAK" ]; then
		cp "$BAK" "$CFG"
		/etc/init.d/sing-box-core restart >/dev/null 2>&1
	else
		rm -f "$CFG"
		/etc/init.d/sing-box-core stop >/dev/null 2>&1
	fi
	exit 4
fi

# 5) 出口探测（不阻断成功，仅提示）
if command -v curl >/dev/null 2>&1; then
	if ! curl -m 6 -sf -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
		echo "配置已生效，但出口探测未通过：请检查节点是否可用" >&2
	fi
fi

exit 0
