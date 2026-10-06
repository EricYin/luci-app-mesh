#!/bin/sh
# luci-app-mesh 共享函数库（busybox ash 兼容）
# 提供无线/射频检测、信道错开、注册表、备份等公共能力

# 路径可用环境变量覆盖（便于测试与定制）；MESH_REGISTRY/MESH_LOG 依赖 MESH_TMP_DIR
MESH_LIBDIR="${MESH_LIBDIR:-/usr/libexec/mesh}"
MESH_STATE_DIR="${MESH_STATE_DIR:-/etc/mesh-state}"
MESH_TMP_DIR="${MESH_TMP_DIR:-/tmp/mesh}"
MESH_BACKUP_DIR="${MESH_BACKUP_DIR:-/etc/mesh-backup}"
MESH_REGISTRY="${MESH_REGISTRY:-$MESH_TMP_DIR/registry.tsv}"
MESH_LOG="${MESH_LOG:-$MESH_TMP_DIR/mesh.log}"
MESH_SYNC_INTERVAL="${MESH_SYNC_INTERVAL:-10}"
MESH_ROLLBACK_SECONDS="${MESH_ROLLBACK_SECONDS:-120}"

# ---------------- 日志 ----------------
mesh_log() {
	local lvl="$1"; shift
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	logger -t "mesh" -p "daemon.$lvl" "$*" 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S') [$lvl] $*" >> "$MESH_LOG" 2>/dev/null
	if [ -s "$MESH_LOG" ] && [ "$(wc -l < "$MESH_LOG" 2>/dev/null)" -gt 600 ]; then
		tail -n 300 "$MESH_LOG" > "$MESH_LOG.tmp" 2>/dev/null && mv "$MESH_LOG.tmp" "$MESH_LOG"
	fi
}

# ---------------- UCI 快捷 ----------------
mesh_uci_get()  { uci -q get "mesh.$1" 2>/dev/null; }
mesh_uci_getd() { local v; v=$(uci -q get "mesh.$1" 2>/dev/null); echo "${v:-$2}"; }

# 列表成员判断：$1 = 待查元素，$2 = 列表（空格分隔 或 换行分隔皆可），命中返回 0。
# 不能写成 `printf '%s\n' "$list" | grep -qxF "$item"`：当 $list 是脚本自己拼出来的
# 空格分隔串（如 newports=" lan1 lan2"）时，printf 只产出一行 " lan1 lan2"，
# 精确匹配必然失败 —— 结果就是元素被无限重复追加进 br-lan 成员表。
# 这里按 IFS 空白切分后逐项精确比对，两种分隔符都能正确处理。
mesh_has() {
	local want="$1" x
	for x in ${2:-}; do
		[ "$x" = "$want" ] && return 0
	done
	return 1
}

# 两个列表是否等价（顺序无关、元素不重复）：用于比较 uci list（换行分隔）与
# 脚本里拼出来的空格分隔串。用途是在重建 br-lan 成员表之前先比对 ——
# uci set/add_list 即便写入相同的值也会留下变更记录，进而触发无谓的
# network restart / wifi reload（一次就是十几秒断网）。
mesh_list_eq() {
	local x a="${1:-}" b="${2:-}" na=0 nb=0
	for x in $a; do
		mesh_has "$x" "$b" || return 1
		na=$((na+1))
	done
	for x in $b; do nb=$((nb+1)); done
	[ "$na" = "$nb" ]
}

# 仅在值变化时才写 UCI。与 meshctl 里的 mset 同义，但 functions.sh 会被
# meshctl / cgi-bin / hotplug 多处复用，这里自带一份，避免依赖调用方先定义 mset。
# 注意：`uci set` 即便值完全相同也会写出一条变更记录，高频路径上会让
# `uci changes` 恒为非空 → 每轮同步都重载无线。这是必须去重的根本原因。
mesh_uci_set_if_changed() {
	local cur
	cur=$(uci -q get "$1" 2>/dev/null)
	[ "$cur" = "$2" ] || uci set "$1=$2"
}

# 确保 UCI 节存在（不存在时才建）：`uci set name=type` 在节已存在、类型也相同时
# 同样会留下变更记录，因此不能无条件调用。
mesh_uci_ensure_section() {
	uci -q get "$1" >/dev/null 2>&1 || uci set "$1=$2"
}

# ---------------- network 接口成员语法：device 还是 ifname（A-3）----------------
# OpenWrt 21.02 把 interface 段的 `option ifname` 换成了 `option device`：
#   · 21.02 起推荐 device；ifname 仍被兼容，但 LuCI 的接口页会一直弹"迁移配置"
#   · 19.07 及更早只认 ifname，写 device 等于没写（接口起不来）
# 本包的 batmesh 段要表达"mesh0 是 bat0 的硬接口"，必须按目标固件的语法落盘，
# 否则要么接口挂不上（老固件），要么后台一进接口页就弹迁移（新固件）。
# 探测顺序（命中即返回，结果缓存在 $MESH_NET_SYNTAX 里，一次启动只探一次）：
#   ① network.loopback.device  —— 新固件的出厂 /etc/config/network 一定带它，最可靠
#   ② /etc/openwrt_release 的 DISTRIB_RELEASE 主版本号 —— >=21 新，<=19 老
#   ③ /usr/share/hostap/ 存在 —— 24.10 起的布局，SNAPSHOT 上靠它定新
#   ④ 都探不出来 -> both（两个都写）：任何固件都能用，只是新固件上仍会弹迁移。
#      实际上 ①② 已经覆盖几乎所有固件，④ 基本走不到。
# 返回：new / old / both
mesh_net_syntax() {
	local rel major
	if [ -n "$MESH_NET_SYNTAX" ]; then
		echo "$MESH_NET_SYNTAX"; return 0
	fi
	MESH_NET_SYNTAX=both
	if [ -n "$(uci -q get network.loopback.device 2>/dev/null)" ]; then
		MESH_NET_SYNTAX=new
	elif [ -r /etc/openwrt_release ]; then
		rel=$(sed -n "s/^DISTRIB_RELEASE=['\"]*\([^'\"]*\)['\"]*.*$/\1/p" \
			/etc/openwrt_release 2>/dev/null | head -n1)
		major=${rel%%.*}
		case "$major" in
			''|*[!0-9]*)
				# SNAPSHOT / 版本号非数字：只能靠目录布局判断
				[ -d /usr/share/hostap ] && MESH_NET_SYNTAX=new
				;;
			*)
				if [ "$major" -ge 21 ]; then
					MESH_NET_SYNTAX=new
				elif [ "$major" -le 19 ]; then
					MESH_NET_SYNTAX=old
				fi
				;;
		esac
	elif [ -d /usr/share/hostap ]; then
		MESH_NET_SYNTAX=new
	fi
	echo "$MESH_NET_SYNTAX"
}

# ---------------- 具名 wifi-iface 段（A-1）----------------
# ★ 为什么必须具名：`uci add wireless wifi-iface` 建出来的是**匿名段**（cfg0xxxxx），
#   LuCI 的无线页一检测到匿名段就弹"迁移配置"（wireless.js 的 checkAnonymousSections）。
#   本工具每次 apply / 开窗都在建段，弹窗于是变成"点开无线页必现"；更糟的是用户点了
#   迁移，LuCI 会把段名改成 wifinetN，而状态文件里记的还是旧名，本工具从此找不到
#   自己建的段（删不掉、改不动，每轮再建一段）。
#   用具名段 + mesh_managed=1 标记彻底解决：名字稳定、可自检、不触发迁移。
#   具名 wifi-iface 在 OpenWrt 全版本（含 19.07）都支持，没有兼容性代价。
#   段名统一 xxmesh_ 前缀，避开与固件自带段 / 用户自建段撞名的可能。
#
# 取一个"当前没被占用"的段名：base、base_2、base_3 ……（只取名，不创建）
mesh_wifi_iface_free_name() {
	local base="$1" sec="$1" n=1
	while uci -q get "wireless.$sec" >/dev/null 2>&1; do
		n=$((n+1)); sec="${base}_$n"
	done
	echo "$sec"
}

# 建一个具名 wifi-iface 段并打上本工具的标记，输出段名（失败输出空）
mesh_wifi_iface_new() {
	local sec
	[ -n "$1" ] || return 1
	sec=$(mesh_wifi_iface_free_name "$1") || return 1
	uci set "wireless.$sec=wifi-iface" 2>/dev/null || return 1
	uci set "wireless.$sec.mesh_managed=1" 2>/dev/null
	echo "$sec"
}

# 把已存在的段改名为 base 系列里的空闲名（已是该系列就原样返回）。
# 用于存量整理：把旧版本留下的匿名段一次性升级成具名段。输出改名后的段名。
mesh_wifi_iface_rename() {
	local old="$1" base="$2" new
	[ -n "$old" ] && [ -n "$base" ] || return 1
	uci -q get "wireless.$old" >/dev/null 2>&1 || return 1
	case "$old" in
		"$base"|"$base"_[0-9]*) echo "$old"; return 0;;
	esac
	new=$(mesh_wifi_iface_free_name "$base") || return 1
	uci -q rename "wireless.$old=$new" 2>/dev/null || return 1
	uci set "wireless.$new.mesh_managed=1" 2>/dev/null
	echo "$new"
}

# ---------------- 状态文件落盘（内容未变则不写） ----------------
# MESH_STATE_DIR 默认在 /etc/mesh-state，属于闪存(overlay)分区；而守护进程每 10 秒
# 都会刷新 my-index / bh-band / master-id / ap-created-* 等状态文件。若直接 "> 文件"，
# 这些文件（内容其实常年不变）每轮都会擦写一次闪存，日积月累造成磨损。
# 统一改走本函数：先把期望内容写到同目录的 .new 临时文件，再与现有文件逐字节比对，
# 完全一致就丢弃临时文件、不产生任何写盘；只有真的变化了才 mv 覆盖。
# 用法：printf '%s\n' "$value" | mesh_state_write "$MESH_STATE_DIR/xxx"
mesh_state_write() {
	local f="$1" tmp="${1}.new"
	mkdir -p "${f%/*}" 2>/dev/null
	cat > "$tmp" 2>/dev/null || return 1
	if [ -f "$f" ] && cmp -s "$tmp" "$f" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null
		return 0
	fi
	mv -f "$tmp" "$f"
}

# ---------------- JSON 辅助（输出侧） ----------------
mesh_esc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g'
}
mesh_jstr() { printf '"%s"' "$(mesh_esc "$1")"; }
mesh_jkv()  { printf '%s:%s' "$(mesh_jstr "$1")" "$(mesh_jstr "$2")"; }

# ---------------- URL 编解码 ----------------
mesh_urlenc() {
	printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/+/%2B/g' \
		-e 's/&/%26/g' -e 's/=/%3D/g' -e 's/?/%3F/g' -e 's/#/%23/g' -e 's/;/%3B/g'
}
# URL 解码（awk 实现，避免依赖 bash 风格参数展开与 printf %b 的 \x 支持）
mesh_urldec() {
	printf '%s' "${1:-}" | awk '
		BEGIN {
			for (i = 32; i < 127; i++) ord[sprintf("%02X", i)] = sprintf("%c", i)
			ord["20"] = " "
		}
		{
			s = $0
			gsub(/\+/, " ", s)
			out = ""
			while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
				out = out substr(s, 1, RSTART - 1)
				out = out ord[toupper(substr(s, RSTART + 1, 2))]
				s = substr(s, RSTART + RLENGTH)
			}
			print out s
		}
	'
}

# ---------------- 无线配置读取 ----------------
mesh_radios() {
	uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'
}
mesh_wifi_ifaces() {
	uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'
}

# radio -> phy 名（优先通过已显式指定 ifname 的接口反查，否则按约定 radioN->phyN）
mesh_radio_phy() {
	local radio="$1" sec ifn p net
	net="${MESH_SYS_NET:-/sys/class/net}"
	for sec in $(mesh_wifi_ifaces); do
		[ "$(uci -q get "wireless.$sec.device" 2>/dev/null)" = "$radio" ] || continue
		ifn=$(uci -q get "wireless.$sec.ifname" 2>/dev/null)
		if [ -n "$ifn" ] && [ -e "$net/$ifn/phy80211" ]; then
			p=$(readlink -f "$net/$ifn/phy80211" 2>/dev/null)
			[ -n "$p" ] && { echo "${p##*/}"; return 0; }
		fi
	done
	case "$radio" in
		radio*) echo "phy${radio#radio}";;
		*) echo "$radio";;
	esac
}

# radio 支持的 htmode 列表（形如 "HT20 VHT20 HT40 VHT40 VHT80"）
#   iwinfo 的 htmodelist 只认"接口名"——用 radio0 / phy1 去问都是空，
#   所以这里先由 mesh_radio_phy 拿到 phy，再枚举该 phy 下的接口去问。
mesh_radio_htmodelist() {
	local radio="$1" phy ifn iphy out net
	net="${MESH_SYS_NET:-/sys/class/net}"
	phy=$(mesh_radio_phy "$radio")
	[ -n "$phy" ] || return 0
	for ifn in $(ls "$net" 2>/dev/null); do
		[ -e "$net/$ifn/phy80211" ] || continue
		iphy=$(readlink -f "$net/$ifn/phy80211" 2>/dev/null)
		[ "${iphy##*/}" = "$phy" ] || continue
		out=$(iwinfo "$ifn" htmodelist 2>/dev/null)
		[ -n "$out" ] && { echo "$out"; return 0; }
	done
	return 0
}

# 把上游(主节点)的 htmode 降级成本地射频支持的等价形态：
#   只跟随"频宽"，代际(HE>VHT>HT)以本地射频支持的最强者为准。
#   混编组网（主节点 WiFi6 / 子节点 WiFi5）时，把上游的 HE80 原样写到只支持 VHT 的
#   射频上，热重载会 netifd: command failed: Not supported (-122)，并把 AP 留在
#   disabled 状态 —— 实测 MT7615 上 5G AP 直接不再广播，只有整 radio 重启才恢复。
#   探测不到本地能力时返回空串，调用方应"保持现状、不要强写"。
mesh_localize_htmode() {
	local radio="$1" want="$2" w list c last
	w="$want"; w=${w#HE}; w=${w#VHT}; w=${w#HT}
	case "$w" in ''|*[!0-9]*) echo "$want"; return 0;; esac
	list=$(mesh_radio_htmodelist "$radio")
	[ -n "$list" ] || return 0
	for c in "HE$w" "VHT$w" "HT$w"; do
		case " $list " in *" $c "*) echo "$c"; return 0;; esac
	done
	# 没有同频宽的项：退回该射频支持的最宽一项（htmodelist 由窄到宽排列）
	for c in $list; do last="$c"; done
	[ -n "$last" ] && echo "$last"
	return 0
}

# 某个 radio 上"非 mesh"的无线接口名（AP 接口）
#   MESH_SYS_NET 可覆盖 sysfs 根路径，仅为测试注入用（与 mesh_wifi_ensure_aps_up 一致）
mesh_radio_ap_ifaces() {
	local radio="$1" phy ifn iphy net
	net="${MESH_SYS_NET:-/sys/class/net}"
	phy=$(mesh_radio_phy "$radio")
	[ -n "$phy" ] || return 0
	for ifn in $(ls "$net" 2>/dev/null); do
		[ -e "$net/$ifn/phy80211" ] || continue
		iphy=$(readlink -f "$net/$ifn/phy80211" 2>/dev/null)
		[ "${iphy##*/}" = "$phy" ] || continue
		case "$ifn" in mesh*) continue;; esac
		echo "$ifn"
	done
}

# 无线热重载(wifi reload)后的兜底自愈。
#   hostapd 的 reload 是"热重载"：在 AP 与 mesh0 共用同一 radio 的设备上（实测
#   MT7615/mt76），netifd 会报 `command failed: Not supported (-122)`，把 AP 接口
#   打到 down 之后**不再自动恢复**（同一份日志里 radio0 的 AP 同样报 -122 却能恢复）。
#   现象就是"主节点改了无线密码 → 子节点同步后 5G AP 直接消失且不广播"。
# 这里在 reload 后逐个 radio 校验：只要该 radio 有启用的 AP 段、而它的 AP 接口
# 一个都没有载波，就对这个 radio 做一次冷重启（wifi down/up）把它拉回来。
# 只在真的坏掉时才动，正常热重载不增加任何开销。
mesh_wifi_ensure_aps_up() {
	local radio sec need ok ifn bad="" settle net
	net="${MESH_SYS_NET:-/sys/class/net}"
	settle=$(mesh_uci_getd main.ap_settle 8)
	sleep "$settle"
	for radio in $(mesh_radios); do
		need=0
		for sec in $(mesh_wifi_ifaces); do
			# 注意：这里必须直接 uci 读 wireless.*，不能用 mesh_uci_get ——
			# 后者只服务于 mesh.* 配置（内部会拼 "mesh." 前缀），传 wireless.* 会恒空。
			[ "$(uci -q get "wireless.$sec.device" 2>/dev/null)" = "$radio" ] || continue
			[ "$(uci -q get "wireless.$sec.mode" 2>/dev/null)" = "ap" ] || continue
			[ "$(uci -q get "wireless.$sec.disabled" 2>/dev/null)" = "1" ] && continue
			need=1; break
		done
		[ "$need" = "1" ] || continue
		ok=0
		for ifn in $(mesh_radio_ap_ifaces "$radio"); do
			[ "$(cat "$net/$ifn/carrier" 2>/dev/null)" = "1" ] && { ok=1; break; }
		done
		[ "$ok" = "1" ] || bad="$bad $radio"
	done
	[ -n "$bad" ] || return 0
	for radio in $bad; do
		mesh_log warn "无线重载后 $radio 上的 AP 未起来，整 radio 冷重启兜底"
		wifi down "$radio" >/dev/null 2>&1
		sleep 2
		wifi up "$radio" >/dev/null 2>&1
	done
	sleep 8
	return 0
}

# radio -> 频段 (2g/5g/6g)
mesh_radio_band() {
	local radio="$1" band ch phy
	band=$(uci -q get "wireless.$radio.band" 2>/dev/null)
	case "$band" in
		2g|5g|6g) echo "$band"; return 0;;
	esac
	# 旧固件：按信道号推断
	ch=$(uci -q get "wireless.$radio.channel" 2>/dev/null)
	case "$ch" in
		auto|"") ;;
		*)
			if [ "$ch" -le 14 ] 2>/dev/null; then echo 2g; return 0; fi
			phy=$(mesh_radio_phy "$radio")
			if iw "$phy" info 2>/dev/null | grep -q ' 5955 MHz'; then
				echo 6g
			else
				echo 5g
			fi
			return 0
			;;
	esac
	case "$(uci -q get "wireless.$radio.hwmode" 2>/dev/null)" in
		*11a*) echo 5g;;
		*) echo 2g;;
	esac
}

mesh_band_radio() {
	local r b
	for r in $(mesh_radios); do
		b=$(mesh_radio_band "$r")
		[ "$b" = "$1" ] && { echo "$r"; return 0; }
	done
	return 1
}

mesh_radio_ap_count() {
	local radio="$1" sec n=0 mode
	for sec in $(mesh_wifi_ifaces); do
		[ "$(uci -q get "wireless.$sec.device" 2>/dev/null)" = "$radio" ] || continue
		mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
		[ "$mode" = "ap" ] && n=$((n+1))
	done
	echo "$n"
}

# radio 当前实际运行的信道（配置 auto 时由驱动选出），取不到返回空串
mesh_radio_running_channel() {
	local radio="$1" sec ifn ch phy
	# 注意不能用 `iwinfo ... | head -n1 && return 0` 的写法：head 的退出码恒为 0，
	# 于是"第一个带 ifname 的接口"之后就直接返回了 —— 后面的接口根本没机会再试。
	# mesh 口排在 AP 口之前、而 mesh 口又取不到信道时，这里会白返回空串，
	# 结果就是主节点上报 real=0，子节点的「跟随主节点实际信道」随之失效。
	for sec in $(mesh_wifi_ifaces); do
		[ "$(uci -q get "wireless.$sec.device" 2>/dev/null)" = "$radio" ] || continue
		ifn=$(uci -q get "wireless.$sec.ifname" 2>/dev/null)
		[ -n "$ifn" ] || continue
		ch=$(iwinfo "$ifn" info 2>/dev/null | sed -n 's/^ *Channel: *\([0-9]*\).*/\1/p' | head -n1)
		[ -n "$ch" ] && { echo "$ch"; return 0; }
	done
	# UCI 里没写 ifname（交给驱动自动命名）时，退一步直接查该射频本身
	phy=$(mesh_radio_phy "$radio")
	if [ -n "$phy" ]; then
		ch=$(iwinfo "$phy" info 2>/dev/null | sed -n 's/^ *Channel: *\([0-9]*\).*/\1/p' | head -n1)
		[ -n "$ch" ] && { echo "$ch"; return 0; }
	fi
	echo ""
}

# radio 支持的信道号列表（含 DFS，按硬件真实能力），用于前端按频段过滤回程信道下拉。
# iw phy info 的频率行形如 "5180 MHz [36] (23.0 dBm)"，信道号在方括号里；
# 没有 iw / 取不到时返回空串（前端会回退到固定列表）。
mesh_radio_channels() {
	local radio="$1" phy
	phy=$(mesh_radio_phy "$radio")
	[ -n "$phy" ] || return 0
	iw phy "$phy" info 2>/dev/null | sed -n 's/.*MHz \[\([0-9][0-9]*\)\].*/\1/p' | sort -n -u
}

# 空格分隔的信道列表 -> 去重排序后的同格式串
mesh_channels_uniq_sorted() {
	echo "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n -u | tr '\n' ' '
}

# 空格分隔的信道列表 -> JSON 数组 "[1,6,11]"
mesh_list_to_json() {
	local out="" x
	for x in $1; do
		case "$x" in ''|*[!0-9]*) continue;; esac
		[ -n "$out" ] && out="$out,"
		out="$out$x"
	done
	printf '[%s]' "$out"
}

# 本机 LAN 管理地址（优先 UCI，其次运行时）
mesh_lan_ip() {
	local a
	a=$(uci -q get network.lan.ipaddr 2>/dev/null)
	[ -n "$a" ] || a=$(ip -4 addr show dev br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1)
	echo "$a"
}

# ================= batman-adv（可选：接管路径选择，替代 802.11s 的 HWMP） =================
# 安装 kmod-batman-adv 后可用。启用后 802.11s 只负责"建立链路"，
# 由 batman-adv 在多条链路(无线回程 / 有线回程)之间按 TQ 选出最优路径。

mesh_batctl() { command -v batctl 2>/dev/null; }

# 模块已安装但还没加载（刚装完没重启）时也要认：先试着 modprobe 一次
mesh_batman_module_ready() {
	local kver found=0 f
	[ -d /sys/module/batman_adv ] && return 0
	kver=$(uname -r 2>/dev/null)
	[ -n "$kver" ] || return 1
	for f in "/lib/modules/$kver"/batman-adv.ko*; do
		[ -e "$f" ] && found=1 && break
	done
	[ "$found" = "1" ] || return 1
	modprobe batman-adv >/dev/null 2>&1
	[ -d /sys/module/batman_adv ] && return 0
	# 模块存在但本次加载失败：仍返回 1，交给调用方报明确错误
	return 1
}

# 具备 batman-adv 能力 = 内核模块已加载、或模块存在且本次能加载成功。
# 不能只看 batctl 是否存在：batctl 只是用户态工具，内核模块缺失时 bat0 根本建不起来，
# 无线回程也就无从谈起（只剩网线一条链路）。因此"模块可加载"必须是硬条件；
# 曾经仅凭 batctl 存在就放行，是个真实风险点。
# 模块在、但本次加载失败（版本不匹配等）时，把结果缓存 MESH_BAT_CAP_SEC 秒，
# 避免状态页每 10 秒都去 modprobe 一次。
mesh_batman_cap() {
	local cache="$MESH_TMP_DIR/batman-cap" now mt r
	# 快速路径：模块已在内存里（常驻，无需任何缓存判断）
	[ -d /sys/module/batman_adv ] && return 0
	now=$(date +%s)
	if [ -r "$cache" ]; then
		mt=$(sed -n '1p' "$cache" 2>/dev/null)
		r=$(sed -n '2p' "$cache" 2>/dev/null)
		case "$mt" in ''|*[!0-9]*) mt=0;; esac
		case "$r" in
			0|1) [ "$((now - mt))" -lt "${MESH_BAT_CAP_SEC:-300}" ] && { [ "$r" = 1 ]; return $?; };;
		esac
	fi
	r=0
	mesh_batman_module_ready && r=1
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	printf '%s\n%s\n' "$now" "$r" > "$cache" 2>/dev/null
	[ "$r" = 1 ]
}

# 内核实际支持的路由算法。返回空表示让内核用默认值（不要硬编码 BATMAN_IV，
# 编译进内核的算法集合因版本而异，写错会导致 bat0 创建失败）
mesh_bat_routing_algo() {
	local f="/sys/module/batman_adv/parameters/routing_algo"
	[ -r "$f" ] || { echo ""; return 0; }
# 注意不能写 grep -qx 'BATMAN_IV'：在部分内核上这个 sysfs 文件打出的是"可用算法列表"
# （形如 `BATMAN_IV[active] BATMAN_V `），精确整行匹配永远失败 —— 结果就是永远退回内核
# 默认算法。而另一些内核（实测两端 batman-adv 2025.4）只给出"当前选中的那一个"
# （就一行 `BATMAN_IV`）。用子串匹配可同时兼容 `BATMAN_IV` / `[BATMAN_IV]` /
# `BATMAN_IV[active]` 三种形态；且 BATMAN_V 与 BATMAN_IV 互不为子串，不会误判。
	tr ' ' '\n' < "$f" 2>/dev/null | grep -q 'BATMAN_IV' && { echo BATMAN_IV; return 0; }
	echo ""
}

# batX 接口名；接口还没起来时退化为读 UCI 里 proto=batadv 的节名
mesh_bat_iface() {
	local n sec
	for n in /sys/class/net/bat*; do
		[ -e "$n" ] && { echo "${n##*/}"; return 0; }
	done
	for sec in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)\.proto=[^a-zA-Z]*batadv.*$/\1/p'); do
		[ -n "$sec" ] && { echo "$sec"; return 0; }
	done
	return 1
}

# bat0 的 hard interface 列表（真实出口：mesh0 走无线 / ethX 走有线）
# 优先用 batctl 问，sysfs 仅作退路：
#   ① batman-adv 2023 起把 /sys/class/net/<hif>/batman_adv 换成了 generic netlink。
#      实测 2025.4（K2P 的 OpenWrt 25.12 与 360T7 的 Kwrt 两端一致）上那个目录
#      **根本不存在**，先扫 sysfs 等于每次都白跑一圈再走退路 —— 顺序必须反过来。
#   ② 免解析差异：batctl 新旧版本 `interface` 的列格式不同（老版 `mesh0: active`，
#      新版空格分隔），这里统一用 sed 取冒号前/空白前的第一段，两种都能命中。
# sysfs 形态（老内核）：每个从属接口下都有 /sys/class/net/<hif>/batman_adv/，它是个
# **目录**，其中 mesh_iface 是指向所属 batX netdev 的符号链接；也有少数版本把
# batman_adv 本身做成符号链接，两种形态这里都处理。
mesh_bat_hardifs() {
	local bat ctl d hif tgt found=0 out
	bat=$(mesh_bat_iface) || return 0
	[ -n "$bat" ] || return 0
	ctl=$(mesh_batctl)
	if [ -n "$ctl" ]; then
		# batman-adv 2023+ 的新式语法；老 batctl 不认 meshif，会打印用法到 stderr(已丢弃)
		out=$("$ctl" meshif "$bat" interface 2>/dev/null | sed -n 's/^\([^ :]*\):.*/\1/p')
		[ -n "$out" ] || out=$("$ctl" -m "$bat" interface 2>/dev/null | sed -n 's/^\([^ :]*\):.*/\1/p')
		[ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
	fi
	for d in /sys/class/net/*/batman_adv; do
		[ -e "$d" ] || continue
		hif=${d#/sys/class/net/}
		hif=${hif%/batman_adv}
		if [ -L "$d" ]; then
			tgt=$(readlink "$d" 2>/dev/null)
			case "${tgt##*/}" in "$bat"|"") ;; *) continue;; esac
		elif [ -e "$d/mesh_iface" ]; then
			tgt=$(readlink "$d/mesh_iface" 2>/dev/null)
			case "${tgt##*/}" in "$bat"|"") ;; *) continue;; esac
		fi
		printf '%s\n' "$hif"
		found=1
	done
	return 0
}

# 出口接口 → 链路类型：mesh*/wlan* 视为无线，其余(eth/br-/bat 等)视为有线
mesh_bat_iface_link() {
	case "$1" in
		mesh*|wlan*) echo wifi;;
		''|-) echo "";;
		*) echo wired;;
	esac
}

# ================= hop_penalty：本包刻意不使用 hardif 级的那一份 =================
# batman-adv 的 **hardif 级** hop_penalty 确实是"这条链路值多少分"的开关
# （net/batman-adv/bat_iv_ogm.c 里 combined_tq 乘上 TQ_MAX - if_incoming->hop_penalty，
# 值越小 → 从这条链路学来的路径 TQ 越高 → 越容易被选中）。
#
# 但它**只在 bat0 上同时挂着有线和无线两种 hardif 时才有意义**。本包唯一实现的
# B 方案里，bat0 的 hardif 只有 mesh0 一个（端口全部走 br-lan 二层桥接，不做 batman
# 封装），所有 OGM 都从同一个 hardif 进来 —— 这时给它扣分只会**无差别**拉低每一条
# 路径的 TQ（单跳 255→225，两跳更狠），既没有第二条链路可比，又白白削弱无线回程。
# 所以本包不写 hardif 级 hop_penalty，让它保持内核默认 0；历史上别种模式写入的值
# 由 mesh_bat_legacy_purge() 清掉。
#
# 注意 mesh 级的 network.bat0.hop_penalty(=30) 与择优无关：它只在"OGM 从某个 WiFi
# 口进来、又从同一个 WiFi 口转发出去"时叠一层半双工惩罚（batadv_is_wifi_hardif
# 分支），是防止无线口回环发大水的保护，本包照常写入。
#
# B 方案的"有线优先"靠的是**网桥二层直转**：两端网口直连 → 两个 br-lan 合成同一个
# 二层域 → 网桥按 MAC 学习直接从网口转发（零 batman 封装开销、满线速）。跨 mesh 的环路
# 交给 bat0 的 bridge_loop_avoidance(BLA)，STP 只管物理口之间的环 —— **bat0 不会被 STP
# 阻塞**（batman-adv 在 tx 路径丢弃 802.1D BPDU，详见 mesh_batman_apply 里的注释）。
# 有网线时单播走网线；拔线后 bat0 本来就在 forwarding，网桥刷新转发表即接管无线。
#
# 实测（2026-09-23，主 10.0.0.1 ↔ 子 10.0.0.117，网线在位，20 个 1200 字节 ping
# ≈24.5KB 载荷）—— 各口字节增量：
#   主 → 子: lan1(cost=5) tx +26512 rx +32650 | bat0 tx +5166 **rx +42**
#   子 → 主: wan (cost=5) tx +26358 rx +24990 | bat0 **tx +0**  rx +84
# 子节点应答这 20 个 ping 期间 **bat0 发送 0 字节**：整条流量都在网线上，无线侧只剩
# OGM/BLA 控制帧（mesh0 收发 2~3KB）。RTT 0.68/1.81/7.92 ms，20/20 无丢包。
# 结论：本拓扑里「惩罚无线路径让 batman 优先有线」无事可做 —— batman 看不到有线路径，
# 给它扣分只会作用在唯一那条 mesh0 上（均匀生效、互相抵消），不是"更优先有线"。

# ---------------- 历史版本残留清理（升级迁移，必须保留） ----------------
# 本包现在只实现 B 方案：物理端口与 bat0 同进 br-lan，bat0 只有 mesh0 一个 hardif。
# 早期版本实现过另外两种有线回程模式，从旧版本升级上来必须把它们的残留拆干净 ——
# 光是残留就足以让设备失联，且**与用户当下选了什么都无关**：
#
#   · C 方案(mesh-on-LAN)：bridge-vlan 节 / 8021q 子接口 / 被抬高的 MTU。
#     netifd 只要看到 bridge-vlan 就会给 br-lan 打开 VLAN filtering，而**没有被任何
#     bridge-vlan 覆盖的端口会被彻底隔离** —— 此时 vlan 定义已不再由本包维护，端口
#     被静默踢出广播域，表现就是管理地址不可达、只能串口恢复。（真机踩到过。）
#   · A 方案：每个内网端口被整成 bat0 的 hardif（batif_* 节），br-lan 成员只剩 bat0。
#     不清掉的话端口永远挂在 bat0 上，二层桥接建立不起来，有线侧等于废掉。
#   · 两种模式都会往 hardif 上写 hop_penalty / throughput_override，一并回落默认。
#
# 幂等：没有任何残留时只做几次只读检查，是安全的 no-op，可以每轮 apply 都调用。
mesh_bat_legacy_purge() {
	local sec f brsec had=0
	brsec=$(mesh_brlan_section)
	# ① 拆掉所有 bridge-vlan 节（无论节名 —— 类型是 bridge-vlan 就要拆）
	for sec in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=bridge-vlan$/\1/p'); do
		uci -q delete "network.$sec"
		had=1
	done
	# ② 拆掉 8021q 子接口节与"为抬高 MTU 而建的 device 节"
	for sec in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
		case "$sec" in
			meshvlan|meshmtu_*) uci -q delete "network.$sec"; had=1;;
		esac
	done
	# ③ 拆掉把内网端口整成 bat0 hardif 的节；batmesh 是无线回程口，必须留
	for sec in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)\.proto=[^a-zA-Z]*batadv_hardif.*$/\1/p'); do
		[ "$sec" = "batmesh" ] && continue
		uci -q delete "network.$sec"
		had=1
	done
	# ④ 历史版本写在无线回程口上的两项。只在确实存在时才删 ——
	#    无条件 uci delete 虽不留变更记录，但会给每次同步多 fork 两个 uci 进程
	for f in hop_penalty throughput_override; do
		[ -n "$(uci -q get "network.batmesh.$f" 2>/dev/null)" ] && uci -q delete "network.batmesh.$f"
	done
	# ⑤ br-lan 被抬高的 MTU 只在"确实找到过残留"时才回退 ——
	#    它不像 STP 有专门的标记文件，无条件删会把用户自己设的 br-lan MTU 一起抹掉
	[ "$had" = "1" ] && [ -n "$brsec" ] && uci -q delete "network.$brsec.mtu" 2>/dev/null
	# ⑥ 老版本把 br-lan 的成员误写进了 device 节的 ifname（选项名判定出错所致）。
	#    device 节上的 ifname 是"父设备"语义、不是成员表，netifd 直接忽略；留着只会让
	#    "br-lan 成员"看起来有值、把真正的问题盖住。节名/name 已由 mesh_brlan_section
	#    保证就是 br-lan，而桥设备不可能有"父设备"，所以删掉是安全的。
	if [ -n "$brsec" ] && [ "$(mesh_section_type "$brsec")" = "device" ] \
	   && [ -n "$(uci -q get "network.$brsec.ifname" 2>/dev/null)" ]; then
		uci -q delete "network.$brsec.ifname" 2>/dev/null
	fi
	return 0
}

# originator 表 → TSV: originator|tq|nexthop|outif|lastseen|gw
#   tq    = 端到端传输质量 0~255，batman-adv 的路径优劣指标
#   outif = batman-adv 实际选中的出口，也就是 bat0 的 hardif。B 方案下 bat0 只有
#           无线 mesh0 一个 hardif，所以它**恒为无线** —— 它表达的是"batman 从哪个
#           hardif 到达对端"，**不是**"数据实际走哪条链路"：网线是 br-lan 的桥端口，
#           根本不是 batman 的路径。界面要显示"实际承载"请用 mesh_brlan_fdb_tsv()，
#           不要把 outif 当成"优先链路"（v1.0.0-r5 及以前的状态页正是这么错的）。
#   gw    = 1 表示 batman-adv 选中的出网网关
# 读侧：优先 debugfs 直读，不可读时回退 batctl。
# debugfs 与 batctl 是同一张表中的同一份数据，但 debugfs 是文件直读：
# 省掉一次 fork，也省掉让 batctl 自己去解析后重新格式化的开销。
# 注意：debugfs 需要内核编入 DEBUG_FS 且 /sys/kernel/debug 已挂载；OpenWrt 默认
# 不挂载它，所以本函数在多数设备上会走 batctl 分支 —— 真正的去重收益来自上层的
# 5 秒结果缓存（见 mesh_bat_originators_tsv），那才是每 10 秒轮询的必经之路。
mesh_bat_originators() {
	local bat ctl f
	bat=$(mesh_bat_iface) || return 0
	[ -n "$bat" ] || return 0
	f="/sys/kernel/debug/batman_adv/$bat/originators"
	if [ -r "$f" ]; then
		cat "$f" 2>/dev/null
		return 0
	fi
	ctl=$(mesh_batctl)
	if [ -n "$ctl" ]; then
		"$ctl" -m "$bat" originators 2>/dev/null
		return 0
	fi
	return 0
}

# 把 originators 输出解析成 TSV（兼容 batctl 新旧版本与 debugfs 直接读取）。
# ① 结果短缓存（MESH_BAT_CACHE_SEC，默认 5 秒）：状态页与诊断可能在很短时间内
#    多次取表，缓存可省掉重复的 fork 与重复解析；5 秒短于守护进程 10 秒轮询，
#    不会让界面看到实质过期的数据。缓存放在 /tmp（tmpfs），不涉及闪存磨损。
# ② 邻居很多时按 TQ 降序只输出前 MESH_BAT_MAX_ORIG 条（默认 128）：
#    下游只关心"每个节点最优的那条路径"，整张表原样落中间文件纯属浪费
#    —— 大 Mesh 里 originator 可达数百条。排序在 awk 内部完成，不额外 fork sort。
mesh_bat_originators_tsv() {
	local cache="$MESH_TMP_DIR/bat-orig.tsv" now mt out
	now=$(date +%s)
	if [ -r "$cache" ]; then
		mt=$(sed -n '1p' "$cache" 2>/dev/null)
		case "$mt" in ''|*[!0-9]*) mt=0;; esac
		if [ "$((now - mt))" -lt "${MESH_BAT_CACHE_SEC:-5}" ]; then
			sed -n '2,$p' "$cache"
			return 0
		fi
	fi
	out=$(mesh_bat_originators | awk -v max="${MESH_BAT_MAX_ORIG:-128}" '
		function ismac(s) {
			return (s ~ /^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]$/)
		}
		{
			line = $0
			if (line !~ /[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:/) next
			gw = (line ~ /\*/) ? 1 : 0
			sub(/^[^0-9a-fA-F]*/, "", line)
			n = split(line, a, /[ \t]+/)
			mac = toupper(a[1])
			if (!ismac(mac)) next
			tq = ""; ls = ""; nex = ""; gwo = ""
			if (match(line, /\([0-9]+\)/)) {
				tq = substr(line, RSTART + 1, RLENGTH - 2)
				head = substr(line, 1, RSTART - 1)
				nh = split(head, h, /[ \t]+/)
				ls = ""
				for (i = nh; i >= 1; i--) if (h[i] != "") { ls = h[i]; break }
				tail = substr(line, RSTART + RLENGTH)
				nt = split(tail, t, /[ \t]+/)
				for (i = 1; i <= nt; i++) if (ismac(t[i])) { nex = toupper(t[i]); break }
			} else {
				for (i = 2; i <= n; i++) if (ismac(a[i])) { nex = toupper(a[i]); break }
			}
			if (match(line, /\[[^]]*\]/)) {
				gwo = substr(line, RSTART + 1, RLENGTH - 2)
				gsub(/[ \t]/, "", gwo)
			}
			total++
			o_mac[total] = mac; o_tq[total] = tq; o_nex[total] = nex
			o_out[total] = gwo; o_ls[total] = ls; o_gw[total] = gw
		}
		END {
			if (total == 0) exit
			lim = max + 0
			if (lim < 1 || lim > total) lim = total
			for (i = 1; i <= lim; i++) {
				best = -1; bi = 0
				for (j = 1; j <= total; j++) {
					if (j in taken) continue
					v = o_tq[j] + 0
					if (v > best) { best = v; bi = j }
				}
				if (bi == 0) break
				taken[bi] = 1
				printf "%s|%s|%s|%s|%s|%s\n", o_mac[bi], o_tq[bi], o_nex[bi], o_out[bi], o_ls[bi], o_gw[bi]
			}
		}
	')
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	# 空表也写入缓存（只有时间戳行），否则链路刚起、表还空时会每轮都重复解析
	if [ -n "$out" ]; then
		printf '%s\n%s\n' "$now" "$out" > "$cache" 2>/dev/null
		printf '%s\n' "$out"
	else
		printf '%s\n' "$now" > "$cache" 2>/dev/null
	fi
	return 0
}

# 出网网关向全网通告的出口带宽。
#   'auto'（默认）或留空 → 千兆口 1000mbit/1000mbit
#   其它值原样返回（允许手工定制，如 '300mbit/100mbit'）
# 之所以要有默认值：batman-adv 内核默认只按 10mbit/2mbit 估算网关出口，
# 不显式通告的话，子节点会低估真正千兆网关的可用带宽而选错路径。
mesh_bat_gw_bandwidth() {
	local v
	v=$(mesh_uci_get main.gw_bandwidth)
	case "$v" in
		''|auto) echo '1000mbit/1000mbit';;
		*) echo "$v";;
	esac
}

# 搭建 batman-adv：bat0(虚拟接口) + hard interface
#   $1 = gw_mode: server(出网网关) / client / off
#
# 本包只实现 B 方案（br-lan 二层桥接），拓扑固定为：
#     物理端口 ─┐
#               ├─ br-lan ── 管理地址 / DHCP / 下挂终端
#     bat0 ─────┘      └── mesh0：802.11s 无线回程，也是 bat0 **唯一**的 hardif
# 两端节点之间拉一根网线 → 两个 br-lan 合成同一个二层域 → 网桥按 MAC 学习直接从
# 网口转发（零 batman 封装开销、满线速）= 有线优先；拔线后 bat0（本就是 forwarding）
# 直接接管无线回程。跨 mesh 的环由 BLA 兜住，STP 只管物理口之间的环（见下面 STP 段）。
# 说明：802.11s 的 mesh_fwding 必须关掉，否则两套转发并存会互相打架。
mesh_batman_apply() {
	local gw="$1" p brsec ports newports algo cur gwbw mopt ufd uma uht uset
	# ① 先清历史版本的残留（bridge-vlan / 8021q 子接口 / batif_* / 被抬高的 MTU）。
	#    必须在写入目标状态**之前**做：残留里的 bridge-vlan 会让 netifd 给 br-lan
	#    打开 VLAN filtering，未被覆盖的端口直接隔离 —— 那样接下来写什么都会失联。
	#    详见 mesh_bat_legacy_purge 的注释。
	mesh_bat_legacy_purge

	# 全部走"变化才写"：apply 会被守护进程在配置跟随主节点时自动调用，
	# 若每次都无条件 uci set，即便值没变也会留下变更记录，进而触发
	# network restart / wifi reload —— 那是一次 10~20 秒的断网。
	mesh_uci_ensure_section network.bat0 interface
	mesh_uci_set_if_changed network.bat0.proto batadv
	algo=$(mesh_bat_routing_algo)
	if [ -n "$algo" ]; then
		mesh_uci_set_if_changed network.bat0.routing_algo "$algo"
	else
		uci -q delete network.bat0.routing_algo 2>/dev/null
	fi
	mesh_uci_set_if_changed network.bat0.aggregated_ogms 1
	mesh_uci_set_if_changed network.bat0.bridge_loop_avoidance 1
	mesh_uci_set_if_changed network.bat0.distributed_arp_table 1
	mesh_uci_set_if_changed network.bat0.multicast_mode 1
	# 注意：这是 **mesh 级** hop_penalty，只在"同一 WiFi 口进又出"时叠加半双工惩罚，
	# 与有线/无线择优无关（那是 hardif 级的那一份，本包不使用，见文件上方注释）。
	mesh_uci_set_if_changed network.bat0.hop_penalty 30
	mesh_uci_set_if_changed network.bat0.orig_interval 1000
	mesh_uci_set_if_changed network.bat0.gw_mode "$gw"
	# 出网网关要向全网通告自己的出口带宽，否则 batman-adv 会按默认的
	# 10mbit/2mbit 估算可用带宽，子节点据此选出的"最优网关"会严重失真
	# （明明有千兆出口，却可能绕去另一个更近但只有 10mbit 的节点）。
	# main.gw_bandwidth: 'auto'（默认）或留空 → 千兆口；
	#                    也可手工写成 '300mbit/100mbit' 之类的定制值。
	gwbw=$(mesh_bat_gw_bandwidth)
	if [ "$gw" = "server" ] && [ -n "$gwbw" ]; then
		mesh_uci_set_if_changed network.bat0.gw_bandwidth "$gwbw"
	else
		uci -q delete network.bat0.gw_bandwidth 2>/dev/null
	fi

	# 无线回程 mesh0 作为 hardif，也是 bat0 **唯一**的 hardif。
	# MTU 必须 ≥ 1500+41，否则内核全程分片
	mesh_uci_ensure_section network.batmesh interface
	mesh_uci_set_if_changed network.batmesh.proto batadv_hardif
	mesh_uci_set_if_changed network.batmesh.master bat0
	# ★ 成员项写 device 还是 ifname 由固件版本决定（A-2 + A-3）。
	#   21.02 起 ifname 是废弃写法，留着会让 LuCI 接口页一直弹"迁移配置"；
	#   19.07 及更早只认 ifname，写 device 等于没写、bat0 拿不到这个硬接口。
	#   探测不出来（both）就两个都写：netifd 只读自己认识的那个，功能不受影响。
	case "$(mesh_net_syntax)" in
		old)
			mesh_uci_set_if_changed network.batmesh.ifname mesh0
			uci -q delete network.batmesh.device 2>/dev/null
			;;
		new)
			mesh_uci_set_if_changed network.batmesh.device mesh0
			uci -q delete network.batmesh.ifname 2>/dev/null
			;;
		*)
			mesh_uci_set_if_changed network.batmesh.device mesh0
			mesh_uci_set_if_changed network.batmesh.ifname mesh0
			;;
	esac
	mesh_uci_set_if_changed network.batmesh.mtu 2304
	# 刻意不写 batmesh.hop_penalty：mesh0 是 bat0 唯一的 hardif，没有第二条链路可与
	# 它比较，扣分只会无差别拉低所有路径的 TQ（见文件上方 hop_penalty 注释）。
	# 历史版本写过的话，开头的 mesh_bat_legacy_purge 已经清掉。

	brsec=$(mesh_brlan_section)
	# 二层环路防护：bat0 与物理端口同在 br-lan 时，两台节点"网线+无线"同时连上就会成环。
	# **跨 mesh 这条环由 bridge_loop_avoidance(BLA) 负责**：它精确处理"同一个客户端在
	# mesh 上和 LAN 上同时可见"，只掐掉重复的那部分（实测：showmacs 里客户端的 MAC 只
	# 落在网口、不在 bat0）。STP 管的是**物理口之间**的环，典型是三台以上节点两两拉
	# 网线那种 bat0 不参与的纯网线环。
	#
	# 别再以为"STP 会阻塞 bat0"—— 本包的注释/文档曾长期这么写，2026-09-23 真机实测推翻：
	# batman-adv 在 tx 路径直接丢弃目的地址 01:80:C2:00:00:00 的帧（soft-interface.c:
	# "don't accept stp packets. STP does not help in meshes. better use the bridge loop
	# avoidance"），BPDU 出不了 bat0 → 对端收不到 → 两端各自把 bat0 当本段唯一的桥，
	# 恒为 forwarding（实测两端 bat0 都是 forwarding，且各自认为自己是 designated bridge）。
	# cost 值本身没错（BATMAN_IV 的 bat0 提不出 link speed，网桥按 802.1D 老表给 cost=100；
	# 实测 bat0=100、有链路的物理网口=5），但它永远走不到"比对 cost"那一步。
	# 于是"有线优先"的实际机制 = 同处一个二层域 + 网桥 MAC 学习（对端客户端只在网口学到）
	# + BLA 抑制经 mesh 绕回来的重复帧 —— 不是 STP 阻塞。
	# OGM / 网关通告走的是 mesh0 硬接口（mesh0 不在网桥里），不经过网桥数据面 ——
	# 网线在位期间邻居表 / TQ / 网关选择照样新鲜，界面上的 TQ 不会"瞎"。
	#
	# 定时器：netifd 的默认是 forward_delay=8 / max_age=10 / hello_time=1
	# （15/20/2 是**内核**默认值，netifd 2021-08 起已改成 8/10/1），三者必须满足
	# 802.1D 的约束              2×(forward_delay−1) ≥ max_age ≥ 2×(hello_time+1)
	# 默认值满足；但把 forward_delay 压到 4 之后，2×(4−1)=6 < 10 就不自洽了 ——
	# 根桥切换期可能出现过期 BPDU 未及时老化导致的瞬时环路，所以 max_age 必须一起
	# 收到 6。压低后：**插**网线时新端口要过 listening+learning，约 2×4 ≈ 8 秒
	# （保持默认 8 则要 ≈16 秒）；拔线方向不用等 STP（bat0 一直是 forwarding）。
	# hello_time 显式写 1，避免老 netifd
	# 默认 2 时右半边不成立（max_age=6 ≥ 2×(2+1)=6 恰好成立，但那是巧合）。
	# 开 STP 的副作用要知道：桥创建/重启后所有端口都要先过 listening+learning 才转发，
	# 即每次 network restart 后内网口约 8 秒不通（保持默认 8 则是 16 秒）。
	#
	# stp 与定时器分两个标记：用户自己就在 br-lan 上开过 STP 时只补定时器、不接管
	# stp（标记缺失 = 拆除时不动它）；用户自定义过定时器时一个都不改，只提示。
	if [ -n "$brsec" ]; then
		mkdir -p "$MESH_STATE_DIR" 2>/dev/null
		if [ "$(uci -q get "network.$brsec.stp" 2>/dev/null)" != "1" ]; then
			uci set "network.$brsec.stp=1"
			: > "$MESH_STATE_DIR/bat-stp"
		fi
		# 只接管「留空（= 正在用的 netifd 默认 8/10/1）或本来就是我们这套 4/6/1」的
		# 定时器；用户显式写了别的值就尊重（他可能按自己网络的直径调过）
		ufd=$(uci -q get "network.$brsec.forward_delay" 2>/dev/null)
		uma=$(uci -q get "network.$brsec.max_age" 2>/dev/null)
		uht=$(uci -q get "network.$brsec.hello_time" 2>/dev/null)
		uset=0
		case "$ufd" in ''|4|8) ;; *) uset=1;; esac
		case "$uma" in ''|6|10) ;; *) uset=1;; esac
		case "$uht" in ''|1) ;; *) uset=1;; esac
		if [ "$uset" = 1 ]; then
			mesh_log info "br-lan 的 STP 定时器由用户自定义（fd=${ufd:-默认} max_age=${uma:-默认} hello=${uht:-默认}），本工具不改动，断线切换时间以该值为准"
		elif [ "$ufd" != 4 ] || [ "$uma" != 6 ] || [ "$uht" != 1 ]; then
			uci set "network.$brsec.forward_delay=4"
			uci set "network.$brsec.max_age=6"
			uci set "network.$brsec.hello_time=1"
			: > "$MESH_STATE_DIR/bat-stp-timer"
		fi
	fi

	# 端口与 bat0 一起进 br-lan —— B 方案的全部内容。
	# 若上一轮是历史版本的模式（物理端口被整成 bat0 的 hardif、br-lan 里只剩 bat0），
	# 这里必须先把端口放回来再追加 bat0；否则 br-lan 里只剩一个虚拟接口，有线侧失联。
	# 被摘掉的 batif_* 节由开头的 mesh_bat_legacy_purge 负责清理。
	if [ -n "$brsec" ]; then
		# 成员选项名按节类型取（device 节/新式桥=ports，老式 interface 桥=ifname）
		mopt=$(mesh_section_members_opt "$brsec")
		ports=$(uci -q get "network.$brsec.$mopt" 2>/dev/null)
		newports=""
		for p in $ports; do
			[ "$p" = bat0 ] && continue
			newports="$newports $p"
		done
		for p in $(mesh_lan_ports); do
			mesh_has "$p" "$newports" || newports="$newports $p"
		done
		mesh_has bat0 "$newports" || newports="$newports bat0"
		# 成员集合没变就不动 UCI（否则每次同步/应用都会触发一次 network 重载）
		cur=$(uci -q get "network.$brsec.$mopt" 2>/dev/null)
		if ! mesh_list_eq "$cur" "$newports"; then
			uci -q delete "network.$brsec.$mopt" 2>/dev/null
			for p in $newports; do uci add_list "network.$brsec.$mopt=$p"; done
		fi
	fi
	return 0
}

# 移除本工具创建的 batman-adv 接口。
# 关键：br-lan 成员里一旦有 bat0，删 bat0 时就必须把物理端口补回去 ——
# 否则 br-lan 会变成只挂着虚拟接口、甚至没有任何成员的桥，设备立即失联。
mesh_batman_remove() {
	local sec brsec p ports newp="" cur mopt
	brsec=$(mesh_brlan_section)
	# 注意 [^a-zA-Z]* —— uci show 给字符串值加单引号（.proto='batadv'），
	# 用 `.batadv` 去匹配等于在赌那个引号一定存在，这里显式跳过非字母字符
	for sec in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)\.proto=[^a-zA-Z]*batadv.*$/\1/p'); do
		uci -q delete "network.$sec"
	done
	[ -n "$brsec" ] || return 0

	# 历史版本的残留（bridge-vlan / 8021q 子接口 / batif_*）必须清干净，而且**不能**放在
	# 下面 `mesh_has bat0 ... || return 0` 之后 —— bat0 不在 br-lan 里时那里会提前返回，
	# 于是 bridge-vlan 永远留在配置里，VLAN filtering 一直开着，端口被一直隔离。
	# （与 apply 路径共用同一个函数，理由见 mesh_bat_legacy_purge 的注释）
	mesh_bat_legacy_purge

	# 只回收本工具写过的：stp 与定时器各有独立标记 ——
	# 用户自己就在 br-lan 上开过 STP（无 bat-stp 标记）→ 不动 stp；
	# 用户自定义过定时器（无 bat-stp-timer 标记）→ 不动定时器。
	if [ -f "$MESH_STATE_DIR/bat-stp" ]; then
		uci -q delete "network.$brsec.stp"
		rm -f "$MESH_STATE_DIR/bat-stp"
	fi
	if [ -f "$MESH_STATE_DIR/bat-stp-timer" ]; then
		uci -q delete "network.$brsec.forward_delay"
		uci -q delete "network.$brsec.max_age"
		uci -q delete "network.$brsec.hello_time"
		rm -f "$MESH_STATE_DIR/bat-stp-timer"
	fi
	mopt=$(mesh_section_members_opt "$brsec")
	ports=$(uci -q get "network.$brsec.$mopt" 2>/dev/null)
	mesh_has bat0 "$ports" || return 0
	# 重建 br-lan 成员：去掉 bat0，补回全部内网端口
	for p in $ports; do
		[ "$p" = bat0 ] && continue
		newp="$newp $p"
	done
	for p in $(mesh_lan_ports); do
		mesh_has "$p" "$newp" || newp="$newp $p"
	done
	cur=$(uci -q get "network.$brsec.$mopt" 2>/dev/null)
	if ! mesh_list_eq "$cur" "$newp"; then
		uci -q delete "network.$brsec.$mopt"
		for p in $newp; do uci add_list "network.$brsec.$mopt=$p"; done
	fi
	return 0
}

# batman-adv 的 hardif MTU 必须容纳 batman 头部(41B)，否则内核报 "MTU too small" 并全程分片。
# netifd 对"外部设备"设置 MTU 的时机不可靠，网络重载后在这里兜底补一次。
mesh_bat_fix_mtu() {
	[ "$(mesh_uci_getd main.batman 0)" = "1" ] || return 0
	command -v ip >/dev/null 2>&1 || return 0
	[ -d /sys/module/batman_adv ] || return 0
	local hif want cur
	for hif in $(mesh_bat_hardifs); do
		[ -e "/sys/class/net/$hif" ] || continue
		case "$hif" in
			mesh*|wlan*) want=2304;;
			*) want=1560;;
		esac
		cur=$(cat "/sys/class/net/$hif/mtu" 2>/dev/null)
		case "$cur" in ''|*[!0-9]*) continue;; esac
		[ "$cur" -ge "$want" ] && continue
		ip link set dev "$hif" mtu "$want" 2>/dev/null
	done
	return 0
}

# ---------------- 能力检测 ----------------
mesh_kernel_mesh_cap() {
	local p
	for p in /sys/class/ieee80211/phy*; do
		[ -e "$p" ] || continue
		iw "${p##*/}" info 2>/dev/null | grep -q 'mesh point' && return 0
	done
	return 1
}

# 已安装包名列表（每行一个）。
# P0 修复：OpenWrt 25.12+ 已用 apk 取代 opkg，固件里根本没有 opkg 命令。
# 原实现写死 `opkg list-installed`，在 apk 系统上恒为空输出 → wpad 能力恒判为不支持
# → meshctl apply 直接报"未安装支持 802.11s 的 wpad"而拒绝应用，组网完全起不来。
# 这里直接读包数据库文件（比调用包管理器 CLI 快得多，也免 fork）：
#   apk : /lib/apk/db/installed，每个包一段，`P:<name>` 是包名
#   opkg: /usr/lib/opkg/status，每个包一段，`Package: <name>`
# 两者都不存在时才回退到 CLI（兼容其它发行版/未来变化）。
mesh_installed_names() {
	local apkdb="${MESH_APK_DB:-/lib/apk/db/installed}"
	local opkgst="${MESH_OPKG_STATUS:-/usr/lib/opkg/status}"
	if [ -r "$apkdb" ]; then
		sed -n 's/^P://p' "$apkdb" 2>/dev/null
		return 0
	fi
	if [ -r "$opkgst" ]; then
		sed -n 's/^Package: *//p' "$opkgst" 2>/dev/null
		return 0
	fi
	if command -v apk >/dev/null 2>&1; then
		apk info 2>/dev/null
		return 0
	fi
	if command -v opkg >/dev/null 2>&1; then
		opkg list-installed 2>/dev/null | awk '{print $1}'
		return 0
	fi
	return 1
}

# 本机安装命令前缀（按实际包管理器给出）：
#   apk  —— OpenWrt 25.12+（固件里是 apk-mbedtls，/lib/apk/db/installed）
#   opkg —— OpenWrt 23.05 及更早
# 提示文案里不要写死其中一种，否则 apk 系统的用户被引导去敲 opkg（反之亦然）。
mesh_pm_install() {
	local apkdb="${MESH_APK_DB:-/lib/apk/db/installed}"
	if [ -r "$apkdb" ] || command -v apk >/dev/null 2>&1; then
		echo "apk update && apk add"
	else
		echo "opkg update && opkg install"
	fi
}

# wpad 完整版(wpad / wpad-openssl / wpad-wolfssl / wpad-mesh-*)支持 802.11s
# 解析包数据库在慢设备上可能耗时数百毫秒，而状态页每 10 秒轮询一次 cmd_status，
# 这里把结果缓存 300 秒，避免把它拖进高频路径
mesh_wpad_mesh_cap() {
	local list cache="$MESH_TMP_DIR/wpad-cap" now mt r
	now=$(date +%s)
	if [ -r "$cache" ]; then
		mt=$(sed -n '1p' "$cache" 2>/dev/null)
		r=$(sed -n '2p' "$cache" 2>/dev/null)
		case "$mt" in ''|*[!0-9]*) mt=0;; esac
		case "$r" in
			0|1) [ "$((now - mt))" -lt 300 ] && { [ "$r" = 1 ]; return $?; };;
		esac
	fi
	list=$(mesh_installed_names 2>/dev/null | sed -n '/^wpad/p')
	r=0
	if [ -n "$list" ]; then
		# 只要存在一个"非 basic/mini"的 wpad 变体就具备 802.11s 能力。
		# wpad-basic* 和 wpad-mini 都不带 mesh point，必须一起排除 —— 少了 wpad-mini
		# 这一项时，装 wpad-mini 的设备会被误判为"支持 mesh"，apply 里却能过校验。
		if printf '%s\n' "$list" | grep -qv 'wpad-basic\|wpad-mini'; then
			r=1
		fi
	fi
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	printf '%s\n%s\n' "$now" "$r" > "$cache" 2>/dev/null
	[ "$r" = 1 ]
}

# 某个包是否已安装（按包名精确匹配，带 300s 缓存，缓存文件按包名分开）。
# 为什么要缓存：解析包数据库在慢设备上要数百毫秒，而状态页每 10 秒轮询一次
# cmd_status，不能把它放进高频路径（与 mesh_wpad_mesh_cap 同样的理由）。
# 为什么按包名而不是 command -v：dawn / umdns 这类守护进程的可执行文件路径
# 在不同固件上不完全一致，而包数据库里的名字是稳定的（apk 的 P: / opkg 的 Package:）。
mesh_pkg_cap() {
	local pkg="$1" cache now mt r
	[ -n "$pkg" ] || return 1
	cache="$MESH_TMP_DIR/pkg-$pkg"
	now=$(date +%s)
	if [ -r "$cache" ]; then
		mt=$(sed -n '1p' "$cache" 2>/dev/null)
		r=$(sed -n '2p' "$cache" 2>/dev/null)
		case "$mt" in ''|*[!0-9]*) mt=0;; esac
		case "$r" in
			0|1) [ "$((now - mt))" -lt 300 ] && { [ "$r" = 1 ]; return $?; };;
		esac
	fi
	r=0
	mesh_installed_names 2>/dev/null | grep -qx "$pkg" && r=1
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	printf '%s\n%s\n' "$now" "$r" > "$cache" 2>/dev/null
	[ "$r" = 1 ]
}

# 漫游引导能力：dawn（各 AP 间交换客户端信号/负载并用 802.11k/v 引导切换）
# 与其邻居发现依赖 umdns，两者缺一则 dawn 看不到别的 AP，只能退化成本地踢除。
mesh_dawn_cap() { mesh_pkg_cap dawn; }
mesh_umdns_cap() { mesh_pkg_cap umdns; }

# ---------------- 信道 ----------------
mesh_channel_valid() {
	local band="$1" ch="$2"
	[ "$ch" = "auto" ] && return 0
	case "$band" in
		2g) [ "$ch" -ge 1 ] 2>/dev/null && [ "$ch" -le 14 ] 2>/dev/null;;
		5g) [ "$ch" -ge 32 ] 2>/dev/null && [ "$ch" -le 196 ] 2>/dev/null;;
		6g) [ "$ch" -ge 1 ] 2>/dev/null && [ "$ch" -le 233 ] 2>/dev/null;;
		*) return 1;;
	esac
}

# 回程信道默认值（按频段）。
# 为什么必须是一个"确定"的值，而不能默认 auto：
#   802.11s mesh point 与 STA 不同 —— STA 会扫描并跟随 AP 的信道，而 mesh 两端必须
#   各自把射频设到同一信道上，才会互相收到对方的信标(beacon)并建立 plink。两端各自
#   auto = 各挑各的信道，几乎必然错开，于是"两个接口都 up、却永远 0 个对端"。
#   （实测过一次：主节点固定 40、子节点 auto 落到 36，就是上面这个现象；子节点还因为
#   拿不到地址被回滚窗口还原。改成两端相同信道后立刻通。）
# 取值理由：
#   2.4G -> 1   1/6/11 这组互不重叠信道中的首个，各国法规都允许
#   5G   -> 36  5150MHz 起"非 DFS"段的首个信道：无需等雷达检测(CAC)、几乎所有 5G
#                射频都支持；40/44/48/149/153/157/161 同样可用，关键是两端一致
#   6G   -> 1   6GHz 全段无 DFS
mesh_default_channel() {
	case "${1:-}" in
		2g) echo 1;;
		5g) echo 36;;
		6g) echo 1;;
		*)  echo 36;;
	esac
}

# ---------------- 后端自动判定的默认值 ----------------
# 以下各项界面上已不再暴露（用户不需要、也不应该去设），取值一律由后端判断。
# 之所以集中在这里而不是散落在各调用点的字面量里：cmd_apply / cmd_status /
# mesh-sync 三处都要读同一套值，散着写迟早会出现"界面看不到、但各处默认值不一致"
# 的隐性偏差 —— 状态页显示 8 个邻居、实际下发却是别的数，这类问题极难排查。

# 回程加密：802.11s mesh point 只支持 WPA3-SAE 系列（open/WPA2 单模均不能建 mesh）。
# 固定 sae，不给用户选择余地 —— 选了别的也组不上网。
mesh_default_encryption() { echo sae; }

# 国家/地区代码：优先沿用系统无线配置里已有的值（用户可能在「网络→无线」里设过），
# 否则 CN。影响可用信道与发射功率，必须与 AP 侧保持一致，不能自己另起一套。
mesh_default_country() {
	local r c
	for r in $(mesh_radios); do
		c=$(uci -q get "wireless.$r.country" 2>/dev/null)
		[ -n "$c" ] && { echo "$c"; return 0; }
	done
	echo CN
}

# Mesh 名称：主节点**未设置**（UCI 为空）时，用本机 MAC 后 6 位派生，
# 形如 XxMesh-143D90（MAC 68:B7:6B:14:3D:90 → 取 143D90，去冒号大写）。
#
# ★ 判定只看"是否为空"（meshctl apply），不认任何魔法值：用户手工填的 id 一律原样保留。
#   所以出厂配置 /etc/config/mesh 里必须写 option mesh_id ''（留空），
#   写死成 OpenWrtMesh 的话新刷机永远走不到这里。
#
# 这么做有两个理由：
#   ① 802.11s 是**按 mesh_id 匹配**才建立 peer 的。全网同固件默认都叫 OpenWrtMesh，
#      邻居的同款设备会在同一信道上反复尝试 SAE 握手然后失败 —— 既干扰空口又刷日志。
#      id 一错开，对方压根不再尝试。注意只改密码改不掉这个：握手照样会发生。
#   ② MAC 出厂固化 —— 主节点恢复出厂后重新算出来还是同一个 id，不会把已组网的子节点甩掉。
# 只用**主节点**的 MAC：子节点必须与主节点用同一个 id 才能建链，各自派生会导致两端不一致
# （子节点应当从主节点领取，见配对流程；现阶段由人工或脚本保证一致）。
mesh_default_mesh_id() {
	local m
	m=$(mesh_primary_mac 2>/dev/null | tr -d ':\r\n' | tr 'a-f' 'A-F')
	[ "${#m}" -ge 6 ] || return 0
	printf 'XxMesh-%s\n' "${m#${m%??????}}"
}

# 回程密码：**为空**时生成 16 位随机串（enc=none 时不需要密码，不生成）。
# 字符集收敛到 [A-Za-z0-9]：这个串同时充当同步 token 拼进 URL 查询参数，
# 含 & # + % 空格 等保留字符会把请求截断（真机踩过，见 mesh_fetch_master 注释）。
mesh_gen_key() {
	local k
	k=$(head -c 32 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\r\n+/=' | head -c 16)
	[ -n "$k" ] || k=$(awk 'BEGIN{srand();printf "%016d", rand()*10000000000000000}')
	printf '%s\n' "$k"
}

# RSSI 接入门限（dBm）：弱于此值的邻居不建立链路。
# -80 是覆盖与质量的折中；链路建立之后路径优劣由 batman-adv 按 TQ 判定，
# 这个门限只负责"要不要连"，不参与选路，所以不需要用户按场景调。
mesh_default_rssi() { echo -80; }

# 单个射频最多同时连接的邻居数。8 足够典型家庭/小型办公组网。
mesh_default_max_peers() { echo 8; }

# ================= 配对（一键加入）=================
#
# 背景：mesh-sync 下发的 mesh 对象**只有 id、没有回程密码**，而出厂/恢复出厂的
# 子节点手里没有任何可用凭证 —— 它连 sync 那道门都敲不开（token 就是回程密码）。
# 于是"加一台新节点"在改造前只能手工填 4 个参数。
#
# 解法是两把钥匙彻底分开：
#   · 配对密码：固件里写死的固定值，**公开也无妨** —— 它只在一扇"平时根本不存在"
#     的门上有效（窗口关闭时配对 AP 压根没起来）。
#   · 回程密码：随机生成、长期固定，只经窗口期那条通道发给新节点，用户全程不用知道。
#
# 流程：主节点开窗（临时起配对 AP） → 新节点用固件固定的配对参数连上来 →
#   DHCP 拿到地址（配对 AP 桥在 lan 上） → GET mesh-sync?action=join 领凭证 →
#   落盘 → 拆掉 STA → 切 mesh 加入正式网络，此后长期有效。
#
# ★ 实现上的三个硬约束（都是实测得来的）：
#   ① 不能用"配对 mesh"：wpa_supplicant 一个进程只允许加入一个 mesh group，
#      真机实测第二个 mesh 起来后正式回程立刻 "Avoiding join because we already
#      joined a mesh group" 被踢掉。所以配对通道只能走 AP/STA。
#   ② STA 要独立 interface 且 defaultroute=0：桥进 br-lan 会与主节点的配对 AP
#      形成二层环路；用 dhcp 又会抢走默认路由（实测 default 被改到 phy0-sta0）。
#   ③ 配对 AP 打 mesh_pair=1 标记：主节点 ap_json() 目前会把所有 mode=ap 段镜像
#      给子节点（这正是"所有节点都广播配对信号"的实现方式），标记用于本地识别。
#      注意标记**不会**随下发传过去 —— 子节点那边看到的就是一个普通 AP。
MESH_PAIR_SSID_DEFAULT='XxMesh-Pair'
MESH_PAIR_KEY_DEFAULT='xxmesh-pair'
MESH_PAIR_IFNAME='pair0'
MESH_PAIR_STA_IFNAME='pairsta0'
MESH_PAIR_NET='pair'
# ★ 配对备用地址（r35）。出厂路由器内网几乎都是 192.168.1.1（或 192.168.x.1），
#   和主节点撞号时"主节点地址"恰好是待入网节点**自己的地址** —— 发往它的报文被
#   内核本地投递，绑设备、钉路由都送不出去（见 r34），网络层无解。
#   换个主节点专属的备用地址就能绕开：开窗期间在 LAN 桥上临时挂这个 /32 别名，
#   待入网节点改连它领凭证。选 192.0.2.1（RFC 5737 TEST-NET-1，真实网络里不存在），
#   既不撞任何内网、也不会被内核当特殊地址处理；关窗立刻摘掉。
MESH_PAIR_ALIAS='192.0.2.1'

# 备用地址挂/摘。只动地址本身，不动配置；进程被杀/重启也不会残留（tmpfs 语义之外
# 还有一个兜底：pair-status 判断窗口只看 expire 文件，别名没摘也只是多一个地址）。
mesh_pair_alias_up() {
	local br
	br=$(mesh_brlan_device 2>/dev/null)
	[ -n "$br" ] || return 1
	ip addr add "$MESH_PAIR_ALIAS/32" dev "$br" 2>/dev/null
	return 0
}
mesh_pair_alias_down() {
	local br
	br=$(mesh_brlan_device 2>/dev/null)
	[ -n "$br" ] || return 1
	ip addr del "$MESH_PAIR_ALIAS/32" dev "$br" 2>/dev/null
	return 0
}

mesh_pair_ssid() { mesh_uci_getd main.pair_ssid "$MESH_PAIR_SSID_DEFAULT"; }
mesh_pair_key()  { mesh_uci_getd main.pair_key  "$MESH_PAIR_KEY_DEFAULT"; }
# 窗口默认时长（秒）；0 = 常开
mesh_pair_window_default() { mesh_uci_getd main.pair_window 600; }
mesh_pair_expire_file() { echo "$MESH_STATE_DIR/pair-expire"; }
mesh_pair_joined_file() { echo "$MESH_STATE_DIR/pair-joined"; }

# 所有"配对 AP"段。两条认定路径：
#   ① 本工具打的 mesh_pair=1 标记（正常路径，零误判）
#   ② 旧版本建的段**不带标记**，只靠状态文件找；状态文件一丢（重启 / 手改 /
#      跨版本升级）就再也删不掉 —— 结果是一个「密码写在固件里、还桥进内网」的
#      AP 长期广播。真机 .219 就是这样中招的：pair-status 显示 open=0，
#      radio0 上却有个 phy0-ap1 在发 XxMesh-Pair。
#      所以补一条内容认定：mode=ap + 配对 SSID + 配对密码 三者同时命中才算。
#      用户自建的同名 AP 不会有"固件里那个固定配对密码"，误删代价可接受。
mesh_pair_ap_sections() {
	local sec ssid key
	ssid=$(mesh_pair_ssid)
	key=$(mesh_pair_key)
	for sec in $(mesh_wifi_ifaces); do
		[ "$(uci -q get "wireless.$sec.mesh_pair" 2>/dev/null)" = "1" ] && { echo "$sec"; continue; }
		[ "$(uci -q get "wireless.$sec.mode" 2>/dev/null)" = "ap" ] || continue
		[ "$(uci -q get "wireless.$sec.ssid" 2>/dev/null)" = "$ssid" ] || continue
		[ "$(uci -q get "wireless.$sec.key" 2>/dev/null)" = "$key" ] && echo "$sec"
	done
	return 0
}

# 本机由本工具创建的配对 AP 段（取第一个）。
mesh_pair_ap_section() {
	local sec st
	st=$(cat "$MESH_STATE_DIR/pair-section" 2>/dev/null)
	if [ -n "$st" ] && uci -q get "wireless.$st" >/dev/null 2>&1; then
		echo "$st"; return 0
	fi
	for sec in $(mesh_pair_ap_sections); do
		echo "$sec"; return 0
	done
	return 1
}

# 兜底清除：把所有配对 AP 段删掉。删到东西才返回 0（调用方据此决定要不要 reload）。
mesh_pair_ap_purge() {
	local sec n=0
	for sec in $(mesh_pair_ap_sections); do
		uci -q delete "wireless.$sec" 2>/dev/null && n=$((n + 1))
	done
	[ "$n" -gt 0 ] || return 1
	uci commit wireless
	rm -f "$MESH_STATE_DIR/pair-section" "$MESH_STATE_DIR/pair-radio" \
		"$MESH_STATE_DIR/ap-created-"*
	return 0
}

# 配对 AP 放哪个射频：优先挑"非回程"的那个 —— 开窗/关窗的 wifi reload 就不会打扰回程。
# 只有一个射频（或回程射频是唯一可用）时退回它自己（AP+AP 共存是标准能力，已实测）。
mesh_pair_radio() {
	local bh bhr r first=""
	bh=$(mesh_resolve_backhaul_band "$(mesh_uci_getd main.band auto)" 2>/dev/null)
	bhr=""
	[ -n "$bh" ] && bhr=$(mesh_band_radio "$bh" 2>/dev/null)
	for r in $(mesh_radios); do
		[ -n "$first" ] || first="$r"
		[ -n "$bhr" ] && [ "$r" = "$bhr" ] && continue
		# 射频被禁用的话起不来，跳过
		[ "$(uci -q get "wireless.$r.disabled" 2>/dev/null)" = "1" ] && continue
		echo "$r"; return 0
	done
	[ -n "$bhr" ] && { echo "$bhr"; return 0; }
	[ -n "$first" ] && echo "$first"
	return 0
}

mesh_pair_sta_purge() {
	# 残留的配对 STA 段（上次加入被中断留下来的）先清掉，避免每次加入都多堆一段。
	# 只动 xxmesh_pair_sta 这个我们自己命名的空间，绝不会碰用户自己的接口。
	local sec n=0
	for sec in $(mesh_wifi_ifaces); do
		case "$sec" in
			xxmesh_pair_sta|xxmesh_pair_sta_*)
				uci -q delete "wireless.$sec" 2>/dev/null && n=$((n+1));;
		esac
	done
	[ "$n" -gt 0 ] && uci commit wireless 2>/dev/null
	return 0
}

mesh_pair_ap_add() {
	local radio sec ssid key
	radio=$(mesh_pair_radio)
	[ -n "$radio" ] || return 1
	ssid=$(mesh_pair_ssid)
	key=$(mesh_pair_key)
	sec=$(mesh_pair_ap_section 2>/dev/null) || sec=""
	[ -n "$sec" ] || sec=$(mesh_wifi_iface_new xxmesh_pair_ap)
	[ -n "$sec" ] || return 1
	# 复用存量段时也要补标记：旧版本建的段、或用户迁移过的段可能没有
	mesh_uci_set_if_changed "wireless.$sec.mesh_managed" 1
	uci set "wireless.$sec.device=$radio"
	uci set "wireless.$sec.mode=ap"
	uci set "wireless.$sec.network=lan"
	uci set "wireless.$sec.ifname=$MESH_PAIR_IFNAME"
	uci set "wireless.$sec.ssid=$ssid"
	uci set "wireless.$sec.encryption=psk2"
	uci set "wireless.$sec.key=$key"
	uci set "wireless.$sec.disabled=0"
	uci set "wireless.$sec.mesh_pair=1"
	uci commit wireless
	mkdir -p "$MESH_STATE_DIR"
	echo "$sec"   > "$MESH_STATE_DIR/pair-section"
	echo "$radio" > "$MESH_STATE_DIR/pair-radio"
	return 0
}

mesh_pair_ap_del() {
	# 走 purge：连旧版本留下的无标记段一起删掉（只删标记段会漏，见上面注释）
	mesh_pair_ap_purge
	rm -f "$MESH_STATE_DIR/pair-section" "$MESH_STATE_DIR/pair-radio" \
		"$(mesh_pair_expire_file)" "$MESH_STATE_DIR/pair.token"
	return 0
}

# 窗口是否开着。只看过期时间戳：expire 文件里是"到期时刻"的 epoch 秒，0 表示常开。
# 重启后 tmpfs 里的 expire 会消失 → 自动关闭，这是期望行为（不会留下一个永远开着的门）。
mesh_pair_window_open() {
	local exp now
	exp=$(cat "$(mesh_pair_expire_file)" 2>/dev/null)
	case "$exp" in ''|*[!0-9]*) return 1;; esac
	[ "$exp" = 0 ] && return 0
	now=$(date +%s)
	[ "$now" -lt "$exp" ] || return 1
	# 时间戳还在、但 AP 段已经没了（被人为删掉）也算关闭
	mesh_pair_ap_section >/dev/null 2>&1
}

# 剩余秒数；-1 = 常开；0 = 未开
mesh_pair_remain() {
	local exp now
	exp=$(cat "$(mesh_pair_expire_file)" 2>/dev/null)
	case "$exp" in ''|*[!0-9]*) echo 0; return 0;; esac
	[ "$exp" = 0 ] && { echo -1; return 0; }
	now=$(date +%s)
	[ "$now" -lt "$exp" ] || { echo 0; return 0; }
	echo $((exp - now))
}

mesh_pair_joined_count() {
	local f n
	f=$(mesh_pair_joined_file)
	n=$(grep -c . "$f" 2>/dev/null)
	case "$n" in ''|*[!0-9]*) n=0;; esac
	echo "$n"
}

# 记录一次成功的凭证领取（按 MAC 去重，同一台重复领取不重复计数）
mesh_pair_joined_add() {
	local mac="$1" f
	[ -n "$mac" ] || return 0
	f=$(mesh_pair_joined_file)
	mkdir -p "$MESH_STATE_DIR"
	grep -qi "^$mac\$" "$f" 2>/dev/null && return 0
	printf '%s\n' "$mac" >> "$f"
}

# ================= 配对：后台任务的进度与结果 =================
#
# 网页上的「开放加入 / 立即关闭 / 一键加入」三个动作都不能同步等：
#   · pair-open / pair-close 会触发 wifi reload（十几秒）
#   · pair-join 最坏要等满 pair_wait 秒（默认 300），领到凭证后还紧接着跑一次
#     apply —— 子节点会把自己改成 DHCP 并 network restart，承载应答的连接必然断
# 所以 rpcd 侧把它们丢到后台、立即返回，结果与进度落在下面这三个文件里，
# 由 meshctl status / pair-status 读出来给界面轮询。
#
# ★ 必须放在 $MESH_TMP_DIR(/tmp/mesh，tmpfs) 而不是 $MESH_STATE_DIR(/etc/mesh-state)：
#   这是"一次操作的进度"，不是需要跨重启保留的状态。写进 /etc 既白耗闪存，
#   重启后还会留一条"上次加入失败"的过时提示。
mesh_pair_busy_file() { echo "$MESH_TMP_DIR/pair-busy"; }   # op=<cmd> start=<epoch>，任务结束后删除
mesh_pair_last_file() { echo "$MESH_TMP_DIR/pair-last"; }   # op/code/time/msg
mesh_pair_log_file()  { echo "$MESH_TMP_DIR/pair.log"; }    # meshctl 的完整输出

# 读后台任务状态，输出一段可直接嵌进 JSON 的对象（meshctl status 用）
mesh_pair_progress_json() {
	local busyf lastf logf op since lop code tm msg line
	busyf=$(mesh_pair_busy_file); lastf=$(mesh_pair_last_file); logf=$(mesh_pair_log_file)
	op=""; since=0
	if [ -f "$busyf" ]; then
		op=$(sed -n 's/^op=//p' "$busyf" 2>/dev/null | head -n1)
		since=$(sed -n 's/^start=//p' "$busyf" 2>/dev/null | head -n1)
		case "$since" in ''|*[!0-9]*) since=0;; esac
	fi
	lop=""; code=2; tm=""; msg=""
	if [ -f "$lastf" ]; then
		lop=$(sed -n 's/^op=//p'   "$lastf" 2>/dev/null | head -n1)
		code=$(sed -n 's/^code=//p' "$lastf" 2>/dev/null | head -n1)
		tm=$(sed -n 's/^time=//p'   "$lastf" 2>/dev/null | head -n1)
		msg=$(sed -n 's/^msg=//p'   "$lastf" 2>/dev/null | head -n1)
		case "$code" in ''|*[!0-9]*) code=2;; esac
	fi
	# 进度行：pair-join 会依次打 [1/4]…[4/4]，给界面一个"确实还在动"的凭据
	line=$(tail -n 1 "$logf" 2>/dev/null)
	printf '{"busy":%s,"op":"%s","since":%s,"last":{"op":"%s","code":%s,"time":"%s","msg":"%s"},"tail":"%s"}' \
		"$([ -n "$op" ] && echo 1 || echo 0)" "$(mesh_esc "${op:--}")" "$since" \
		"$(mesh_esc "${lop:--}")" "$code" "$(mesh_esc "$tm")" "$(mesh_esc "$msg")" \
		"$(mesh_esc "$line")"
}

# 同上，但输出 key=value 行（meshctl pair-status 用，rpcd 原样透传给前端）
mesh_pair_progress_lines() {
	local busyf lastf logf op since line
	busyf=$(mesh_pair_busy_file); lastf=$(mesh_pair_last_file); logf=$(mesh_pair_log_file)
	op=""; since=0
	if [ -f "$busyf" ]; then
		op=$(sed -n 's/^op=//p' "$busyf" 2>/dev/null | head -n1)
		since=$(sed -n 's/^start=//p' "$busyf" 2>/dev/null | head -n1)
		case "$since" in ''|*[!0-9]*) since=0;; esac
	fi
	echo "busy=$([ -n "$op" ] && echo 1 || echo 0)"
	echo "busy_op=${op:--}"
	echo "busy_since=$since"
	if [ -f "$lastf" ]; then
		echo "last_op=$(sed -n 's/^op=//p' "$lastf" 2>/dev/null | head -n1)"
		echo "last_code=$(sed -n 's/^code=//p' "$lastf" 2>/dev/null | head -n1)"
		echo "last_time=$(sed -n 's/^time=//p' "$lastf" 2>/dev/null | head -n1)"
		echo "last_msg=$(sed -n 's/^msg=//p' "$lastf" 2>/dev/null | head -n1)"
	fi
	# 进度行放最后：前端按行解析时取最后一行即可，不会被上面的空值干扰
	line=$(tail -n 1 "$logf" 2>/dev/null)
	echo "tail=$line"
}

# 扫描配对信号所在的信道。
#
# ★★ 这个函数是必需的，别删。同一个 phy 上的所有接口共享**一个**信道，
#   STA 没法独自跳到别的信道去 —— 真机实测：子节点射频在 ch11、配对 AP 在 ch1 时，
#   wpa_supplicant 一直关联不上（接口建得出来、就是拿不到 IP）；把射频切到 ch1 后
#   立刻 Connected 并拿到 DHCP。所以起 STA 之前必须先把射频对齐到配对信号的信道。
#
# $1 = radio（如 radio0）  $2 = 配对 SSID
mesh_pair_scan_channel() {
	local radio="$1" ssid="$2" phy num ifn freq ch i
	phy=$(mesh_radio_phy "$radio" 2>/dev/null)
	[ -n "$phy" ] || return 1
	num=${phy#phy}
	# 借该射频上现有的任意一个接口来扫（AP 口就行）；扫描会有秒级中断，配对场景可接受
	ifn=$(iw dev 2>/dev/null | awk -v p="phy#$num" '/^phy#/{cur=$1} $1=="Interface"{if(cur==p){print $2; exit}}')
	[ -n "$ifn" ] || return 1
	freq=""
	for i in 1 2; do
		freq=$(iw dev "$ifn" scan ssid "$ssid" 2>/dev/null \
			| awk -v s="$ssid" '/freq:/{f=$2} $1=="SSID:"{if($2==s) print f}' | head -n1)
		[ -n "$freq" ] && break
		sleep 2
	done
	[ -n "$freq" ] || return 1
	freq=${freq%.*}
	case "$freq" in ''|*[!0-9]*) return 1;; esac
	if [ "$freq" -lt 2500 ] 2>/dev/null; then
		ch=$(( (freq - 2407) / 5 ))
	else
		ch=$(( (freq - 5000) / 5 ))
	fi
	[ "$ch" -gt 0 ] 2>/dev/null || return 1
	echo "$ch"
}

# 信道错开：master 信道 -> 节点序号 idx(>=1) 的错开信道
# 2.4G 互不重叠组 {1,6,11}；5G 在 36-48 与 149-161 两组间交替拉开
mesh_base_member() {
	case "$1" in
		2g)
			if [ "$2" -le 2 ] 2>/dev/null; then echo 1
			elif [ "$2" -le 8 ] 2>/dev/null; then echo 6
			else echo 11
			fi
			;;
		5g)
			if [ "$2" -lt 100 ] 2>/dev/null; then echo 36; else echo 149; fi
			;;
		6g) echo 1;;
	esac
}

mesh_stagger_channel() {
	local band="$1" ch="$2" idx="$3" set base i c n target
	case "$idx" in
		''|0) echo "$ch"; return;;
	esac
	case "$band" in
		2g) set="1 6 11";;
		5g) set="36 149 44 157 40 153 48 161";;
		6g) set="1 5 9 13 17 21 25 29";;
		*) echo "$ch"; return;;
	esac
	base=$(mesh_base_member "$band" "$ch")
	n=$(echo $set | wc -w)
	i=0
	for c in $set; do
		[ "$c" = "$base" ] && break
		i=$((i+1))
	done
	[ "$i" -ge "$n" ] && i=0
	target=$(( (i + idx) % n ))
	i=0
	for c in $set; do
		[ "$i" = "$target" ] && { echo "$c"; return; }
		i=$((i+1))
	done
	echo "$ch"
}

mesh_resolve_backhaul_band() {
	local want="$1" b
	case "$want" in
		2g|5g|6g) echo "$want"; return;;
	esac
	for b in 5g 6g 2g; do
		[ -n "$(mesh_band_radio "$b")" ] && { echo "$b"; return; }
	done
}

# ---------------- 按键（WPS 键时长分档）与 LED 反馈 ----------------
# 实现方式：**不备份、不覆盖任何系统文件** —— /etc/rc.button/wps 是个分发器
# （遍历 /etc/rc.wps/*，返回 0 即 break），我们只放一个 /etc/rc.wps/10-mesh。
# 代价是只能在 released（松手）时被调到，$SEEN 是按住秒数，因此**按住期间没有
# 渐进提示**，LED 只做"松手后"的结果反馈（收不到 pressed，不是不想做）。

MESH_LED_DIR="${MESH_LED_DIR:-/sys/class/leds}"
MESH_BTN_LAST="${MESH_BTN_LAST:-$MESH_TMP_DIR/button-last}"
MESH_BTN_PENDING="${MESH_BTN_PENDING:-$MESH_TMP_DIR/button-pending-exit}"
MESH_BTN_CANCEL="${MESH_BTN_CANCEL:-$MESH_TMP_DIR/button-cancel-exit}"
MESH_LED_TOKEN="${MESH_LED_TOKEN:-$MESH_TMP_DIR/led-token}"

mesh_button_last_file()   { echo "$MESH_BTN_LAST"; }
mesh_button_pending_file(){ echo "$MESH_BTN_PENDING"; }
mesh_button_cancel_file() { echo "$MESH_BTN_CANCEL"; }

# 总开关：关掉时 rc.wps 脚本 exit 1 让位给系统自带的 WPS
mesh_button_enabled() { [ "$(mesh_uci_getd main.button 1)" != "0" ]; }

# 档位数值全部 UCI 可配，改数值不用重编固件。
# 出厂默认：加入 ≤4s / 开窗 5~9s / 空档 10~13s / 退出 14~20s / >20s 忽略。
mesh_btn_num() {
	local v
	v=$(mesh_uci_getd "main.$1" "$2")
	case "$v" in ''|*[!0-9]*) v="$2";; esac
	echo "$v"
}
mesh_btn_join_max() { mesh_btn_num btn_join_max 4; }
mesh_btn_open_min() { mesh_btn_num btn_open_min 5; }
mesh_btn_open_max() { mesh_btn_num btn_open_max 9; }
mesh_btn_exit_min() { mesh_btn_num btn_exit_min 14; }
mesh_btn_exit_max() { mesh_btn_num btn_exit_max 20; }
mesh_btn_exit_grace() { mesh_btn_num btn_exit_grace 10; }

# SEEN → 档位：join / open / idle(空档) / exit / none(超长忽略)
mesh_button_classify() {
	local seen="${1:-0}" jmax omin omax emin emax
	case "$seen" in ''|*[!0-9]*) seen=0;; esac
	jmax=$(mesh_btn_join_max); omin=$(mesh_btn_open_min); omax=$(mesh_btn_open_max)
	emin=$(mesh_btn_exit_min); emax=$(mesh_btn_exit_max)
	if [ "$seen" -le "$jmax" ]; then echo join; return; fi
	if [ "$seen" -ge "$omin" ] && [ "$seen" -le "$omax" ]; then echo open; return; fi
	if [ "$seen" -ge "$emin" ] && [ "$seen" -le "$emax" ]; then echo exit; return; fi
	# 开窗档与退出档之间刻意留的空档：人手按不准整数秒，从"想开窗"滑到
	# "退出组网"的代价太大，这一段什么都不做。
	if [ "$seen" -gt "$jmax" ] && [ "$seen" -lt "$emin" ]; then echo idle; return; fi
	echo none
}

# 记录本次按键结果（网页状态页据此显示"本次由按键触发"）
mesh_button_last() {  # $1=op $2=seen $3=code $4=msg
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	{
		echo "op=$1"
		echo "seen=${2:-0}"
		echo "code=${3:-0}"
		echo "time=$(date +%s)"
		echo "msg=$(printf '%s' "${4:-}" | tr '\n' ' ')"
	} > "$MESH_BTN_LAST" 2>/dev/null
}

# 退出组网的反悔窗口：pending 文件存 deadline，cancel 文件是"用户按了第二下"
mesh_button_exit_pending() {
	local f deadline now
	f=$(mesh_button_pending_file)
	[ -f "$f" ] || return 1
	deadline=$(cat "$f" 2>/dev/null); now=$(date +%s)
	case "$deadline" in ''|*[!0-9]*) rm -f "$f"; return 1;; esac
	[ "$now" -lt "$deadline" ] || { rm -f "$f" "$MESH_BTN_CANCEL"; return 1; }
	return 0
}
mesh_button_exit_cancel() {
	: > "$(mesh_button_cancel_file)" 2>/dev/null
	mesh_log info "按键：取消退出组网（反悔窗口内再次按下）"
}

# ---------------- LED ----------------
# 选灯：UCI mesh.main.button_led 指定优先，否则按 phone → wlan → power 回退
# （这三台会选中完全空闲的 blue:phone；blue:wlan 的 trigger 是 phy0radio，
#  闪它会盖掉真实的射频状态，所以排在后面；都没有才用第一个找到的灯）。
mesh_led_pick() {
	local d="${MESH_LED_DIR}" want led last=""
	[ -d "$d" ] || return 1
	want=$(mesh_uci_get main.button_led)
	if [ -n "$want" ] && [ -d "$d/$want" ]; then echo "$want"; return 0; fi
	for pat in phone wlan power; do
		for led in "$d"/*; do
			[ -d "$led" ] || continue
			case "${led##*/}" in *"$pat"*) echo "${led##*/}"; return 0;; esac
		done
	done
	for led in "$d"/*; do [ -d "$led" ] && last="${led##*/}"; done
	[ -n "$led$last" ] && echo "$last"
}

# 危险操作（被拒绝 / 退出前的反悔窗口）用红灯，颜色本身就是信号
mesh_led_pick_danger() {
	local d="${MESH_LED_DIR}" led
	[ -d "$d" ] || return 1
	for led in "$d"/red*; do
		[ -d "$led" ] || continue
		echo "${led##*/}"; return 0
	done
	mesh_led_pick
}

mesh_led_orig_trigger() {  # trigger 文件里形如 "[none] timer ..."，取方括号里那个
	local f="${MESH_LED_DIR}/$1/trigger" t=""
	[ -r "$f" ] || return 1
	t=$(tr ' ' '\n' < "$f" 2>/dev/null | sed -n 's/^\[\(.*\)\]$/\1/p' | head -n1)
	[ -n "$t" ] && echo "$t"
}

mesh_led_save() {  # 记下原 trigger，动作结束要还原（只记一次，已有不覆盖）
	local led="$1" f t
	[ -n "$led" ] || return 1
	f="$MESH_TMP_DIR/led-orig.$led"
	[ -s "$f" ] && return 0
	t=$(mesh_led_orig_trigger "$led")
	[ -n "$t" ] || t=none
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	echo "$t" > "$f" 2>/dev/null
}

# 闪烁循环靠 token 判定自己是否"过时"：换 token = 让上一个闪烁退出。
# 不能用 kill：后台闪烁可能由另一次按键触发，杀名字会误伤。
mesh_led_stop() {
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	echo "$(date +%s).$$" > "$MESH_LED_TOKEN" 2>/dev/null
}

mesh_led_restore_one() {  # 把某一盏灯还原成进入前的 trigger
	local led="$1" t
	[ -n "$led" ] || return 0
	t=$(cat "$MESH_TMP_DIR/led-orig.$led" 2>/dev/null)
	[ -n "$t" ] || t=none
	echo "$t" > "${MESH_LED_DIR}/$led/trigger" 2>/dev/null
	rm -f "$MESH_TMP_DIR/led-orig.$led"
	return 0
}

mesh_led_blink_bg() {  # $1=灯 $2=亮(秒) $3=灭(秒) $4=持续秒
	local led="$1" on="$2" off="$3" dur="$4" tok end
	[ -n "$led" ] || return 0
	tok=$(cat "$MESH_LED_TOKEN" 2>/dev/null)
	end=$(( $(date +%s) + ${dur:-3} ))
	(
		while [ "$(date +%s)" -lt "$end" ]; do
			[ "$(cat "$MESH_LED_TOKEN" 2>/dev/null)" = "$tok" ] || exit 0
			echo 1 > "${MESH_LED_DIR}/$led/brightness" 2>/dev/null
			sleep "${on:-0.5}"
			echo 0 > "${MESH_LED_DIR}/$led/brightness" 2>/dev/null
			sleep "${off:-0.5}"
		done
		# 闪完自己收尾：fail/deny/warn 这类"闪几下就结束"的动作没有别人来还原，
		# 不还原这盏灯就一直停在 trigger=none（blue:wlan 是 phy0radio，等于把
		# 射频指示灯弄坏了）。token 变了说明已被后续动作接管，交给它处理。
		[ "$(cat "$MESH_LED_TOKEN" 2>/dev/null)" = "$tok" ] || exit 0
		t=$(cat "$MESH_TMP_DIR/led-orig.$led" 2>/dev/null)
		[ -n "$t" ] || t=none
		echo "$t" > "${MESH_LED_DIR}/$led/trigger" 2>/dev/null
		rm -f "$MESH_TMP_DIR/led-orig.$led" "$MESH_TMP_DIR/led-current"
	) >/dev/null 2>&1 &
}

mesh_led_act() {  # busy(执行中慢闪) ok(成功常亮10s) fail(失败急闪3s)
	local kind="$1" led danger=0 prev
	case "$kind" in deny|warn|exit) danger=1;; esac
	if [ "$danger" = 1 ]; then led=$(mesh_led_pick_danger); else led=$(mesh_led_pick); fi
	[ -n "$led" ] || return 0
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	# 换灯了（比如"执行中"用蓝灯、"被拒绝"改用红灯）：先把上一盏还原，
	# 否则它会一直停在 trigger=none —— 没人再记得它原来是什么。
	prev=$(cat "$MESH_TMP_DIR/led-current" 2>/dev/null)
	[ -n "$prev" ] && [ "$prev" != "$led" ] && mesh_led_restore_one "$prev"
	mesh_led_stop
	echo "$led" > "$MESH_TMP_DIR/led-current" 2>/dev/null
	mesh_led_save "$led"
	echo none > "${MESH_LED_DIR}/$led/trigger" 2>/dev/null
	case "$kind" in
		busy) mesh_led_blink_bg "$led" 0.5 0.5 3600;;   # 常驻闪，由 clear 收尾
		ok)   echo 1 > "${MESH_LED_DIR}/$led/brightness" 2>/dev/null
		      ( sleep 10; mesh_led_clear ) >/dev/null 2>&1 & ;;
		fail) mesh_led_blink_bg "$led" 0.15 0.15 3;;
		deny) mesh_led_blink_bg "$led" 0.12 0.12 3;;
		warn) mesh_led_blink_bg "$led" 0.2 0.2 "$(mesh_btn_exit_grace)";;
		hold) echo 1 > "${MESH_LED_DIR}/$led/brightness" 2>/dev/null;;  # 开窗期间常亮
	esac
	return 0
}

mesh_led_clear() {  # 停闪 + 还原原 trigger（开窗的 hold 也走这里收尾）
	local led
	led=$(cat "$MESH_TMP_DIR/led-current" 2>/dev/null)
	mesh_led_stop
	mesh_led_restore_one "$led"
	rm -f "$MESH_TMP_DIR/led-current"
	return 0
}

# ---------------- 运行时状态 ----------------
# 当前已启用的 mesh 接口（如 mesh0）
mesh_mesh_ifaces() {
	iw dev 2>/dev/null | awk '$1=="Interface"{ifn=$2} $1=="type"&&$2=="mesh"{print ifn}'
}

# mesh 邻居(station dump) -> JSON 数组
mesh_stations_json() {
	local raw ifn
	raw=$(
		for ifn in $(mesh_mesh_ifaces); do
			iw dev "$ifn" station dump 2>/dev/null | awk -v ifn="$ifn" '
				function flush() {
					if (mac != "")
						printf "{\"mac\":\"%s\",\"ifname\":\"%s\",\"signal\":\"%s\",\"tx\":\"%s\",\"time\":\"%s\",\"plink\":\"%s\"},\n", mac, ifn, sig, tx, ct, plink
				}
				BEGIN { mac = ""; sig = "-"; tx = "-"; ct = "-"; plink = "-" }
				/^Station / { flush(); mac = $2; sig = "-"; tx = "-"; ct = "-"; plink = "-"; next }
				/^[ \t]*signal:/ { sub(/^[ \t]*signal:[ \t]*/, ""); sub(/[ \t]*dBm.*$/, ""); sig = $0; next }
				/^[ \t]*tx bitrate:/ { sub(/^[ \t]*tx bitrate:[ \t]*/, ""); sub(/[ \t].*$/, ""); tx = $0; next }
				/^[ \t]*connected time:/ { sub(/^[ \t]*connected time:[ \t]*/, ""); sub(/[ \t].*$/, ""); ct = $0; next }
				/plink/ { if (mac != "") { sub(/^[ \t]*/, ""); sub(/.*:[ \t]*/, ""); plink = $0 } next }
				END { flush() }
			'
		done
	)
	if [ -z "$(printf '%s' "$raw" | tr -d ' \n')" ]; then
		echo "[]"
		return
	fi
	printf '['
	printf '%s' "$raw" | sed -e '$s/,$//'
	printf ']'
}

mesh_primary_mac() {
	local p
	for p in /sys/class/net/eth*; do
		[ -r "$p/address" ] && { cat "$p/address" 2>/dev/null; return 0; }
	done
	cat /sys/class/net/br-lan/address 2>/dev/null
}

# 本机所有 mesh 接口的 MAC（大写、逗号分隔）
# 用途：无线邻居表里出现的是「对端 mesh 接口 MAC」，与节点上报的 eth* MAC 不同，
#       必须靠这张映射表才能把同一个物理节点的有线/无线两条证据合并成一条。
mesh_mesh_iface_macs() {
	local ifn out="" m
	for ifn in $(mesh_mesh_ifaces); do
		m=$(cat "/sys/class/net/$ifn/address" 2>/dev/null)
		[ -n "$m" ] || continue
		m=$(printf '%s' "$m" | tr 'a-f' 'A-F')
		out="$out${out:+,}$m"
	done
	printf '%s' "$out"
}
mesh_hostname() { uci -q get system.@system[0].hostname 2>/dev/null || echo "openwrt"; }
mesh_board()    { cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown"; }
mesh_fwver()    { . /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_DESCRIPTION:-OpenWrt}"; }

mesh_route_dev() { ip route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\) .*/\1/p' | head -n1; }

# 主节点地址解析链：① 用户配置(mesh.main.master_addr) ② 默认路由网关 ③ 兜底 192.168.1.1
# （厂商默认 LAN 网段，兜底是为了"子节点与主节点同网段且没填地址"时也能开箱即用）。
# 正常情况下 ② 就够了：子节点的内网地址由主节点 DHCP 分发（apply 恒写 proto=dhcp），
# 拿到的默认网关就是主节点。① 只是"子节点不在主节点网段"这类场景下的可选覆盖，可留空。
# ③ 的坑：DHCP 还没完成时本机没有默认路由，兜底值可能就是**子节点自己**（若它的内网
# 地址恰好是 192.168.1.1）—— 请求发给自己必然失败，而报错只会说"无法从主节点获取
# 配置"，用户看不出真实原因是"还不知道主节点在哪"。
# 因此调用方必须先过 mesh_ip_is_local() 判定自己打自己的情形（见 meshctl cmd_sync_once）。
mesh_master_addr() {
	local a
	a=$(mesh_uci_get main.master_addr)
	if [ -z "$a" ]; then
		a=$(ip route show default 2>/dev/null | sed -n 's/^default via \([0-9.]*\) .*/\1/p' | head -n1)
	fi
	[ -n "$a" ] || a=192.168.1.1
	echo "$a"
}

# 该地址是否已挂在本机任一接口上。用于识别"兜底地址 == 本机地址"的自我请求
# （自己给自己发 HTTP 请求，永远拿不到配置，且会掩盖真正的原因）。
mesh_ip_is_local() {
	local want
	want="${1%%/*}"
	[ -n "$want" ] || return 1
	ip -4 addr show 2>/dev/null | grep -qF "inet $want/"
}

# ---------------- 互斥锁 ----------------
# 取锁；超过 60 秒的陈旧锁自动清理，避免进程被杀后永久卡死
_lock_take() {
	local dir="$1" max="$2" i=0 cleared=0
	mkdir -p "${dir%/*}" 2>/dev/null
	while :; do
		mkdir "$dir" 2>/dev/null && return 0
		if [ "$cleared" = 0 ] && [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
			cleared=1
			rmdir "$dir" 2>/dev/null
			continue
		fi
		i=$((i+1))
		[ "$i" -gt "$max" ] && return 1
		sleep 0.1 2>/dev/null || sleep 1
	done
}

mesh_lock() { _lock_take "$MESH_TMP_DIR/lock" 50; }
mesh_unlock() { rmdir "$MESH_TMP_DIR/lock" 2>/dev/null; }

reg_lock() { _lock_take "$MESH_TMP_DIR/registry.lock" 30; }
reg_unlock() { rmdir "$MESH_TMP_DIR/registry.lock" 2>/dev/null; }

# ---------------- 子节点注册表（内存文件，避免闪存磨损） ----------------
# 字段: mac|ip|hostname|board|fw|link|first_seen|last_seen|wmac
#        wmac = 该子节点 mesh 接口(无线)MAC，逗号分隔；用于把无线邻居归并到本节点
# 返回该节点的序号(1 起，按首次注册时间排序；0 为主节点)

# 节点离线多久后从注册表剔除（秒），默认 1 小时。
# 下限取 60 秒：太短会把「正在重启/升级」的节点也删掉，而序号是按首次注册时间排的，
# 删掉再注册等于重新排号 —— 信道错开的分配会跟着跳。
# 上限不设：想让离线节点一直挂着就把 peer_ttl 调大（例如 86400）。
mesh_registry_ttl() {
	local v
	v=$(mesh_uci_getd main.peer_ttl 3600)
	case "$v" in ''|*[!0-9]*) v=3600;; esac
	[ "$v" -ge 60 ] 2>/dev/null || v=3600
	echo "$v"
}

# 单独跑一次清理。
# 注册表平时只在「有子节点上报」时才顺带清理（见 mesh_registry_update 末尾），
# 于是会出现：最后一台子节点掉线后，全网再没有上报发生，那条幽灵行就一直挂在
# 列表里没人清。status 是界面每 10 秒都会调的路径，在这里主动清一遍最省事。
mesh_registry_prune() {
	[ -f "$MESH_REGISTRY" ] || return 0
	local now ttl
	now=$(date +%s)
	ttl=$(mesh_registry_ttl)
	reg_lock || return 0
	awk -F'|' -v now="$now" -v ttl="$ttl" '$8+0 >= now-ttl' \
		"$MESH_REGISTRY" > "$MESH_REGISTRY.p" 2>/dev/null \
		&& mv "$MESH_REGISTRY.p" "$MESH_REGISTRY"
	rm -f "$MESH_REGISTRY.p"
	reg_unlock
}
mesh_registry_update() {
	local mac="$1" ip="$2" host="$3" board="$4" fw="$5" link="$6" wmac="$7"
	local now first found=0 m rest tmp idx _f1 _f2 _f3 _f4 _f5 _f7 _f8
	now=$(date +%s)
	first=$now
	wmac=$(printf '%s' "${wmac:-}" | tr 'a-f' 'A-F')
	mkdir -p "$MESH_TMP_DIR"
	touch "$MESH_REGISTRY"
	reg_lock || { mesh_log warn "注册表加锁失败，本次按序号 1 处理"; echo 1; return 1; }
	tmp="$MESH_REGISTRY.new"
	: > "$tmp"
	while IFS='|' read -r m rest; do
		[ -z "$m" ] && continue
		if [ "$m" = "$mac" ]; then
			# rest 是"去掉 MAC 后的剩余字段"，所以 first_seen 落在 rest 的第 6 段
			# （对应整行第 7 列）。写成 -f7 会取到 last_seen —— 等于每次同步都把
			# 「首次注册时间」刷成「上次同步时间」，排序键一直漂移，节点序号就稳不住。
			# 这里用内建 read 切分（而非 `printf|cut`）—— 注册表每轮同步都全量扫描，
			# 逐行 fork 一个 cut 在慢设备上开销可观。
			IFS='|' read -r _f1 _f2 _f3 _f4 _f5 first _f7 _f8 <<EOF
$rest
EOF
			case "$first" in ''|*[!0-9]*) first=$now;; esac
			printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$m" "$ip" "$host" "$board" "$fw" "$link" "$first" "$now" "$wmac" >> "$tmp"
			found=1
		else
			# 旧记录可能只有 8 个字段，补齐 wmac 列
			case "$rest" in *'|'*'|'*'|'*'|'*'|'*'|'*)
				printf '%s|%s\n' "$m" "$rest" >> "$tmp";;
			*)
				printf '%s|%s|\n' "$m" "$rest" >> "$tmp";;
			esac
		fi
	done < "$MESH_REGISTRY"
	[ "$found" = "0" ] && printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$mac" "$ip" "$host" "$board" "$fw" "$link" "$now" "$now" "$wmac" >> "$tmp"
	# 按首次注册时间排序，并清理超时未上线的节点（阈值见 mesh_registry_ttl）。
	# 第二键必须带 MAC：两台子节点同时第一次上电（同一秒注册）时，若排序结果不确定，
	# 节点序号会在两次同步之间来回跳，信道错开结果也跟着跳
	sort -t'|' -k7,7n -k1,1 "$tmp" | awk -F'|' -v now="$now" -v ttl="$(mesh_registry_ttl)" '$8+0 >= now-ttl' > "$MESH_REGISTRY.t"
	mv "$MESH_REGISTRY.t" "$MESH_REGISTRY"
	rm -f "$tmp"
	idx=0
	while IFS='|' read -r m rest; do
		idx=$((idx+1))
		[ "$m" = "$mac" ] && break
	done < "$MESH_REGISTRY"
	reg_unlock
	echo "$idx"
}

mesh_registry_json() {
	[ -f "$MESH_REGISTRY" ] || return 0
	awk -F'|' '
		function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
		NR > 1 { printf ",\n" }
		{
			printf "{\"mac\":\"%s\",\"ip\":\"%s\",\"hostname\":\"%s\",\"board\":\"%s\",\"fw\":\"%s\",\"link\":\"%s\",\"first\":\"%s\",\"last\":\"%s\",\"index\":%d,\"wmac\":\"%s\"}",
				esc($1), esc($2), esc($3), esc($4), esc($5), esc($6), $7, $8, NR, esc($9)
		}
	' "$MESH_REGISTRY"
}

# ---------------- UCI 节结构小工具（端口 / 网桥判定共用） ----------------

# 取节的类型：interface / device / switch / switch_vlan / bridge-vlan / route …
# 让 uci 自己解析节名，再只认"节声明"那一行（键里只有一层点号 = 声明，两层 = 选项）。
# **不能**把节名拼进 sed 正则：匿名节的节名形如 @device[0]，其中 [0] 会被 sed 当成
# 字符类，`^network\.@device[0]=` 实际被解释成 `^network\.@device0=` —— 永远匹配不上。
# 后果不是"少显示一行"：mesh_section_members_opt 靠类型区分 ports / ifname，
# 类型取不到就会把 device 节（现代 DSA 的 br-lan 就是匿名 device 节）判成老式
# interface 桥、返回 ifname —— 端口与 bat0 全被写进 device 节根本不认的 ifname 里，
# br-lan 成员永远是空的、组网不通；更糟的是"端口内网化"自检读的是同一个错选项，
# 于是显示"全部端口已并入"（假绿）。
# uci 的两种打印形态都要兼容：`uci show network` 里匿名节是 @device[n]，
# 而 `uci show network.@device[n]` 打印的却是自动生成的 cfgXXXXXX 节名 ——
# 所以只按"点号层数"识别声明行，不依赖节名长什么样。
mesh_section_type() {
	[ -n "$1" ] || return 1
	uci -q show "network.$1" 2>/dev/null | awk -F= 'NF >= 2 && split($1, p, ".") == 2 { print $2; exit }'
}

# 所有 interface 节名
mesh_network_ifaces() {
	uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'
}

# 按 name 选项反查 device 节名。config device 常是匿名节，只能这样找。
mesh_device_section_by_name() {
	local s
	[ -n "$1" ] || return 1
	for s in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
		[ "$(uci -q get "network.$s.name" 2>/dev/null)" = "$1" ] && { echo "$s"; return 0; }
	done
	return 1
}

# 一个节的"成员列表"选项名：device 节 / 新式网桥在 ports 里；
# 老式把桥直接写在 interface 节上（option type 'bridge'）时成员在 ifname 里。
# 选项名写错 uci 不报错、只是静默不生效 —— 端口永远进不了内网（实机踩到过）。
mesh_section_members_opt() {
	local sec="$1" t
	[ -n "$sec" ] || { echo ports; return 0; }
	t=$(mesh_section_type "$sec")
	# ① device 节（现代 DSA 的 br-lan 就是匿名 device 节）的成员只可能在 ports。
	#    哪怕它同时写了 type 'bridge' 也不能给 ifname —— device 节上的 ifname 是
	#    "父设备"语义（8021q / macvlan 之类），netifd 不把它当成员表，直接忽略。
	[ "$t" = "device" ] && { echo ports; return 0; }
	# ② 老式：桥直接写在 interface 节上（option type 'bridge'），成员才在 ifname
	if [ "$t" = "interface" ] && [ "$(uci -q get "network.$sec.type" 2>/dev/null)" = "bridge" ]; then
		echo ifname; return 0
	fi
	# ③ 类型取不到（非常规节名 / 老固件）时按选项兜底：已经有 ports 就是 ports
	if [ -n "$(uci -q get "network.$sec.ports" 2>/dev/null)" ]; then echo ports; return 0; fi
	[ "$(uci -q get "network.$sec.type" 2>/dev/null)" = "bridge" ] && { echo ifname; return 0; }
	echo ports
}

# 这个节是不是"桥"：显式 type=bridge，或带 ports 的 device 节
# （device 节只要写了 ports，netifd 就按桥处理，不必显式写 type=bridge）。
# 显式写了别的类型（bonding / 8021q / vlan …）的一律不当桥，避免误摘别人的成员表。
mesh_section_is_bridge() {
	local sec="$1" t
	[ -n "$sec" ] || return 1
	t=$(uci -q get "network.$sec.type" 2>/dev/null)
	[ "$t" = "bridge" ] && return 0
	[ -n "$t" ] && return 1
	[ "$(mesh_section_type "$sec")" = "device" ] && \
		[ -n "$(uci -q get "network.$sec.ports" 2>/dev/null)" ] && return 0
	return 1
}

# 一个 interface 节外扩到的设备/端口名（device / ifname / ports 三个选项）
mesh_iface_devs() {
	local k v
	for k in device ifname ports; do
		for v in $(uci -q get "network.$1.$k" 2>/dev/null); do printf '%s\n' "$v"; done
	done
}

# 本工具自己创建的接口（bat0 / 无线回程口 / 历史 batif_*）不参与上行清理
mesh_iface_is_mesh() {
	case "$1" in bat0|batmesh|batif_*) return 0;; esac
	case "$(uci -q get "network.$1.proto" 2>/dev/null)" in
		batadv|batadv_hardif|batadv_vlan) return 0;;
	esac
	return 1
}

# br-lan 的设备名（DSA：device 节的 name 选项；老式把桥写在 lan 接口上：就是 br-lan）
mesh_brlan_device() {
	local brsec d
	brsec=$(mesh_brlan_section)
	if [ -n "$brsec" ]; then
		d=$(uci -q get "network.$brsec.name" 2>/dev/null)
		[ -n "$d" ] && { echo "$d"; return 0; }
	fi
	d=$(uci -q get network.lan.device 2>/dev/null)
	[ -n "$d" ] && { echo "$d"; return 0; }
	echo "br-lan"
}

# 设备名是否属于 br-lan —— 子节点"不许删"的底线（删了它就彻底失联）。
# $2 可传入预算好的 br-lan 设备名：批量判定时避免每次都去 uci 反查。
mesh_dev_is_brlan() {
	local d="$1" brdev="$2"
	[ -n "$d" ] || return 1
	[ "$d" = "br-lan" ] && return 0
	[ -z "$brdev" ] && brdev=$(mesh_brlan_device)
	[ -n "$brdev" ] && [ "$d" = "$brdev" ] && return 0
	return 1
}

# 设备名是否落在"物理端口"集合里。含父子关系：上行口写成 eth0，而端口集合里
# 只有它的 VLAN 子接口 eth0.1（或反过来）时，也要算命中。
mesh_dev_is_phys() {
	local d="$1" p
	case "$d" in ''|@*) return 1;; esac
	for p in ${2:-}; do
		[ "$p" = "$d" ] && return 0
		case "$d" in "$p".*) return 0;; esac
		case "$p" in "$d".*) return 0;; esac
	done
	return 1
}

# 已知一个"桥设备名"，反查它的成员端口列表。
# 两条路都要走：device 节常用匿名节名 + name 选项（只能反查），
# 也可能是节名就等于设备名（老固件常见）；老式 interface 桥的成员在 ifname 里。
mesh_bridge_members_by_name() {
	local d="$1" sec
	[ -n "$d" ] || return 0
	case "$d" in @*) return 0;; esac
	sec=$(mesh_device_section_by_name "$d")
	if [ -n "$sec" ]; then
		uci -q get "network.$sec.ports" 2>/dev/null
		return 0
	fi
	if mesh_section_is_bridge "$d"; then
		uci -q get "network.$d.$(mesh_section_members_opt "$d")" 2>/dev/null
	fi
	return 0
}

# ---------------- 子节点：清掉所有"占着物理端口的上行 / 旁路接口" ----------------
# 子节点的目标是"所有物理端口都是内网口"，所以任何仍占着物理端口、把端口挡在
# br-lan 之外的接口都必须删掉。只按名字删 wan/wan6 一定会漏（实机与各固件上见过）：
#   ① 节名不叫 wan —— internet / wanb / modem / wwan / pppoe / lte，还有匿名节；
#   ② wan6 写 `option device '@wan'`：删掉 wan 后它成了悬空引用，netifd 报
#      "has no device"，而它仍会去争取一个上行地址；
#   ③ 固件把 WAN 单独做成一个桥（br-wan / br-iptv）：删 `network.wan` 这个**接口**
#      并不会删掉那个 **device 节**，端口仍挂在桥上 → 端口怎么都进不了内网；
#   ④ swconfig 目标上 WAN 是 eth0.2，它同样要进 br-lan（由 mesh_all_physical_ports 枚举）。
# 所以判定准绳是"是否占用物理端口"，名字规则只作兜底（覆盖 device 写成 eth0 这类
# 父接口、或接口压根没写 device 的情形）。桥本身留给 mesh_uci_detach_other_bridges 清。
mesh_uci_remove_upstream() {
	local phys brdev brsec sec d v bsec tgt pass round hit keep
	phys=$(mesh_all_physical_ports)
	[ -n "$phys" ] || return 0
	brdev=$(mesh_brlan_device)
	# 承载 br-lan 的那个节本身绝不能删（老式固件的 br-lan 就是 lan 接口本身；
	# 若某个固件把它起成别的名字，也得靠这条保住）
	brsec=$(mesh_brlan_section)

	# ① 名字就是上行口的（大小写不敏感；`wan*` 不会命中 wlan*）
	for sec in $(mesh_network_ifaces); do
		case "$sec" in lan|loopback) continue;; esac
		[ -n "$brsec" ] && [ "$sec" = "$brsec" ] && continue
		mesh_iface_is_mesh "$sec" && continue
		case "$(printf '%s' "$sec" | tr 'A-Z' 'a-z')" in
			wan*|*_wan*|usbwan*|wwan*|modem*|pppoe*|lte*) ;;
			*) continue;;
		esac
		# 名字像上行口、但 device 指向 br-lan 的（固件的第二内网接口常见这样命名）保留
		keep=0
		for d in $(mesh_iface_devs "$sec"); do
			mesh_dev_is_brlan "$d" "$brdev" && { keep=1; break; }
		done
		[ "$keep" = 1 ] && continue
		uci -q delete "network.$sec"
		mesh_log info "子节点：删除上行接口 network.$sec"
	done

	# ② 剩余接口里"占着物理端口"的 —— 节名任意，匿名节同样覆盖
	for sec in $(mesh_network_ifaces); do
		case "$sec" in lan|loopback) continue;; esac
		[ -n "$brsec" ] && [ "$sec" = "$brsec" ] && continue
		mesh_iface_is_mesh "$sec" && continue
		hit=0; keep=0
		for d in $(mesh_iface_devs "$sec"); do
			mesh_dev_is_brlan "$d" "$brdev" && { keep=1; break; }
			mesh_dev_is_phys "$d" "$phys" && hit=1
		done
		# 端口不在本节自己的 device 上，而在它引用的那个桥（device 节）的 ports 里
		if [ "$hit" = 0 ] && [ "$keep" = 0 ]; then
			for d in $(uci -q get "network.$sec.device" 2>/dev/null); do
				case "$d" in @*) continue;; esac
				mesh_dev_is_brlan "$d" "$brdev" && { keep=1; break; }
				bsec=$(mesh_device_section_by_name "$d")
				[ -n "$bsec" ] || continue
				for v in $(uci -q get "network.$bsec.ports" 2>/dev/null); do
					mesh_dev_is_phys "$v" "$phys" && { hit=1; break; }
				done
				[ "$hit" = 1 ] && break
			done
		fi
		[ "$keep" = 1 ] && continue
		if [ "$hit" = 1 ]; then
			uci -q delete "network.$sec"
			mesh_log info "子节点：删除占用物理端口的上行/旁路接口 network.$sec"
		fi
	done

	# ③ 引用 `@xxx` 的节：被引用的接口已经删了，自己也要删，否则留一堆悬空引用。
	#    最多迭代 5 轮以处理链式引用；`@type[n]` 这类匿名写法跳过（解析不到就不动）。
	pass=0
	while [ "$pass" -lt 5 ]; do
		pass=$((pass + 1)); round=0
		for sec in $(mesh_network_ifaces); do
			case "$sec" in lan|loopback) continue;; esac
			mesh_iface_is_mesh "$sec" && continue
			for v in $(uci -q get "network.$sec.device" 2>/dev/null) \
			         $(uci -q get "network.$sec.ifname" 2>/dev/null); do
				case "$v" in @*) ;; *) continue;; esac
				tgt=${v#@}
				case "$tgt" in *'['*) continue;; esac
				[ -n "$tgt" ] || continue
				[ -n "$(uci -q get "network.$tgt" 2>/dev/null)" ] && continue
				uci -q delete "network.$sec"
				mesh_log info "子节点：删除悬空引用 network.$sec（引用的 $tgt 已不存在）"
				round=1
				break
			done
		done
		[ "$round" = 0 ] && break
	done
	return 0
}

# ---------------- 物理端口并入 br-lan（子节点所有端口设为内网口） ----------------
mesh_all_physical_ports() {
	local p ports="" base
	# 注意去重：`/sys/class/net/eth*` 也会匹配到 eth0.1 / eth0.2（VLAN 子接口），
	# 而它们在第一个循环里已经加过一遍。不去重的话物理端口枚举会出现重复项
	# （诊断页显示成 "物理端口枚举: eth0.1 eth0.2 eth0.1 eth0.2"）。
	if [ -x /sbin/swconfig ] && swconfig list 2>/dev/null | grep -q .; then
		# swconfig 目标：VLAN 子接口（eth0.1/eth0.2 …）全部并入即全端口内网
		for p in /sys/class/net/eth*.*; do
			[ -e "$p" ] || continue
			base=${p##*/}
			mesh_has "$base" "$ports" && continue
			ports="$ports $base"
		done
		# 独立网卡（无 VLAN 子接口的 eth1 等）也要并入；已作为 VLAN 父接口的裸 ethX 跳过
		for p in /sys/class/net/eth*; do
			[ -e "$p" ] || continue
			base=${p##*/}
			case " $ports " in
				*" $base."*) continue;;
			esac
			mesh_has "$base" "$ports" && continue
			ports="$ports $base"
		done
	# ★ 判据是"lan* 或 wan* **任一**存在"，不能写成
	#     ls -d /sys/class/net/lan* /sys/class/net/wan* >/dev/null
	#   —— 只要有一个 glob 没匹配上，整条 ls 就返回非 0，于是掉进下面的 eth* 兜底，
	#   把 DSA 的 conduit(eth0) 当成物理口。真机踩到过：这几台上行是 pon0 光口，
	#   压根没有 wan* 端口（2026-10-05），结果"端口内网化"永远是 false。
	elif [ -n "$(ls -d /sys/class/net/lan* /sys/class/net/wan* 2>/dev/null)" ]; then
		# DSA 目标：lan1..lanN / wan 用户端口
		for p in /sys/class/net/lan* /sys/class/net/wan*; do
			[ -e "$p" ] || continue
			base=${p##*/}
			# 跳过 VLAN 子接口（lan1.1 之类），它们不是物理口
			case "$base" in *.*) continue;; esac
			mesh_has "$base" "$ports" && continue
			ports="$ports $base"
		done
	else
		# 其它：eth0 / eth1 ... 物理网卡
		for p in /sys/class/net/eth*; do
			[ -e "$p" ] || continue
			base=${p##*/}
			mesh_has "$base" "$ports" && continue
			ports="$ports $base"
		done
	fi
	echo "$ports" | tr -s ' '
}

# ---------------- WAN 上行口（主节点必须保留，不能并入内网） ----------------
# 返回 UCI 里 wan/wan6 接口所使用的设备名（DSA 的 wan 口、swconfig 的 eth0.2、PPPoE 的 eth0 等）
mesh_wan_devices() {
	local sec devs="" d ifn proto
	for sec in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
		[ "$sec" = lan ] && continue
		[ "$sec" = loopback ] && continue
		proto=$(uci -q get "network.$sec.proto" 2>/dev/null)
		case "$proto" in
			dhcp|dhcpv6|static|pppoe|pppoa|pptp|l2tp|qmi|modemmanager|ncm|wwan|3g|4g|6in4|6rd|6to4|dslite|map|vti|gre|wireguard) ;;
			*) continue;;
		esac
		# 有默认路由嫌疑的接口都算上行口（多拨/多 WAN 场景也能覆盖）
		for d in $(uci -q get "network.$sec.device" 2>/dev/null) \
				 $(uci -q get "network.$sec.ifname" 2>/dev/null) \
				 $(uci -q get "network.$sec.ports" 2>/dev/null); do
			case "$d" in
				''|@*) continue;;
			esac
			# br-lan 本身绝不是上行口。某些固件有第二个内网接口（lan2 之类）把
			# device 指向 br-lan，它同样是 proto=static：若把它记进来，下面那段
			# "上游桥的成员也纳入排除集"会把 br-lan 自己的全部成员当成上行口，
			# 结果 mesh_lan_ports 变空 → 端口反被从 br-lan 里清出去（内网失联）。
			mesh_dev_is_brlan "$d" && continue
			case " $devs " in *" $d "*) ;; *) devs="$devs $d";; esac
		done
	done
	# swconfig 上还可能是 switch VLAN 名（network.@switch_vlan 里的 wan），
	# 退一步：把 network.wan 的 ifname/device 已覆盖，这里再补 wan 口的 VLAN 子接口
	#
	# 还有一类固件把 WAN 单独做成一个桥：network.wan.device=br-wan，而真正接对端的是
	# br-wan 的成员端口（wan）。只记下 "br-wan" 是不够的 —— mesh_lan_ports 拿物理口名
	# （wan）逐个比对，跟 "br-wan" 匹配不上，于是 wan 会被当成内网口从上游桥里摘走，
	# 主节点当场断上行。这里把上游桥的成员端口一并纳入排除集。
	# 注意 device 节常是匿名的（config device 无节名），只能按 name 选项反查。
	local bbp ifn
	for d in $devs; do
		bbp=$(mesh_bridge_members_by_name "$d")
		[ -n "$bbp" ] || continue
		for ifn in $bbp; do
			case "$ifn" in
				''|@*) continue;;
			esac
			case " $devs " in *" $ifn "*) ;; *) devs="$devs $ifn";; esac
		done
	done
	echo "$devs" | tr -s ' '
}

# ---------------- 光口上行检测 + network 改动的生效方式 ----------------
# 存在光口（PON/EPON/GPON）上行时，**不能**用 `/etc/init.d/network restart` 落地
# network 改动。原因（2026-10-06 真机实测）：
#   /etc/init.d/network 的 stop_service() 是 `wifi down` + `ifdown -a` + 重启 netifd，
#   关的是**全部**接口，光口也不例外。pon0 被 down/up 后 airoha-xpon 驱动会重启
#   注册状态机（dmesg: "XG-PON RX started, irq=53, ONU-ID=1023 (invalid)"），
#   而驱动明确要求"carrier 直到 O5 才 up" —— 注册完成前 wan(pon0) 拿不到地址，
#   表现为外网全断、PON 状态页「线路停止」。用户反馈的"启用主节点就断网"就是它。
#   对照实验：`ubus call network reload` 后 dmesg 无任何 PON 事件、路由不变 ——
#   reload 只重建"配置有变化"的接口，不会去碰 pon0。
# 判据两条：UCI 里上行接口的设备名以 pon/gpon/xpon/epon 开头；或系统里存在这类 netdev
# （有的机型压根没建 wan 接口，但光口 netdev 一定在）。
mesh_has_pon_uplink() {
	local d
	for d in $(mesh_wan_devices); do
		case "$d" in pon*|gpon*|xpon*|epon*) return 0;; esac
	done
	[ -n "$(ls -d /sys/class/net/pon* /sys/class/net/gpon* /sys/class/net/epon* 2>/dev/null)" ] && return 0
	return 1
}

# 光口是不是"真的在用"：从没 carrier up 过（carrier_up_count=0）说明这台根本没走
# PON 上行（比如插的是普通网线），后面那些为光口准备的兜底动作就不必做。
mesh_pon_ever_up() {
	local d
	for d in /sys/class/net/pon*; do
		[ -e "$d" ] || continue
		case "$(cat "$d/carrier_up_count" 2>/dev/null)" in
			''|0) continue;;
			*) return 0;;
		esac
	done
	return 1
}

# network 改动落盘并生效：能增量 reload 就 reload，必要时才 restart。
#   $1 = 场景标签（只用于日志）  $2 = 角色（client 恒 restart，见下）
# 为什么子节点不跟着改 reload：子节点要删上行接口、把 WAN 物理口从别的桥摘出来再
# 并进 br-lan，这类"设备归属变更"正是当初选 restart 的原因；而且子节点不需要上行。
mesh_net_commit() {
	local tag="${1:-apply}" role="${2:-}"
	[ -n "$(uci changes network)" ] || return 0
	uci commit network
	if [ "$(mesh_uci_getd main.net_restart 0)" != "1" ] \
	   && [ "$role" != client ] && mesh_has_pon_uplink; then
		ubus call network reload >/dev/null 2>&1
		sleep 3
		if mesh_net_state_ok; then
			mesh_log info "$tag：network 改动以 reload 生效（检测到光口上行，避免 restart 打断 PON 注册）"
			return 0
		fi
		mesh_log warn "$tag：reload 后关键接口未就绪，降级为 network restart"
	fi
	/etc/init.d/network restart >>"$MESH_LOG" 2>&1
	sleep 3
	mesh_omci_recover
	return 0
}

# reload 到底生效没有：br-lan 必须有地址（否则本机已不可管理）；开了 batman-adv
# 时 bat0 还必须真的挂进 br-lan（只在 UCI 里有、运行时没挂上 = 二层域不通）。
mesh_net_state_ok() {
	ip -4 addr show dev br-lan 2>/dev/null | grep -q 'inet ' || return 1
	if [ "$(mesh_uci_getd main.enabled 0)" = "1" ] && [ "$(mesh_uci_getd main.batman 1)" = "1" ]; then
		[ -e /sys/class/net/br-lan/brif/bat0 ] || return 1
	fi
	return 0
}

# ★★ 注意区分两件事，名字里都有 "pon"，别混：
#   ① **重启 pon0 接口**（ip link set pon0 down/up、ifdown -a）→ airoha-xpon 驱动
#      重启注册状态机，要重做 SerDes 初始化 + O1~O5 注册 —— 这是**断网元凶**，本包
#      现在绝不在有光口时做（改走 reload，见 mesh_net_commit）。
#   ② **重启 airoha-pond 进程**（下面这件事）→ 它只是用户态 OMCI 代理，重启它
#      **不会**动 pon0 接口、不会触发驱动重新初始化，只是让 OMCI 状态机重跑一遍。
#      这是**救 PON** 的动作，不是断 PON。
# 只在"确实被迫走了 restart"（reload 没生效 / 子节点 / 强制开关）之后才考虑：
#   airoha-pond 由 procd 独立管理，只配了 respawn 与 file /etc/config/pon，
#   **没有 watch network.interface** —— netifd 重启不会带着它重启，它的注册状态机
#   可能就卡在 pon0 被 down 那一刻（用户只能重启整台设备才恢复）。
# 三道门槛，缺一不做：有光口 / 这台真的在用 PON 上行（carrier 曾 up 过）/
# 等 15 秒后 carrier 仍未恢复。走 reload 的正常路径根本到不了这里。
mesh_omci_recover() {
	mesh_has_pon_uplink || return 0
	mesh_pon_ever_up || return 0
	[ -x /etc/init.d/airoha-pond ] || return 0
	local d i
	for i in 1 2 3; do
		for d in /sys/class/net/pon*; do
			[ -e "$d" ] || continue
			[ "$(cat "$d/carrier" 2>/dev/null)" = "1" ] && return 0
		done
		sleep 5
	done
	/etc/init.d/airoha-pond restart >/dev/null 2>&1
	mesh_log warn "被迫 network restart 后 PON 未自行恢复，已重启 OMCI 代理进程 airoha-pond（未动 pon0 接口）"
	return 0
}

# br-lan 里"有载波的物理成员" —— apply 前打基线、apply 后验存活。
# 只取物理口的原因：无线 AP 口的 carrier 会随终端关联状态变化，bat0 这类虚拟口
# 根本没有 carrier 文件，把它们算进基线会误判（校验时刚好没终端在线 → 误以为写坏）。
mesh_brlan_carrier_ports() {
	local net="${MESH_SYS_NET:-/sys/class/net}" d p
	[ -d "$net/br-lan/brif" ] || return 0
	for d in "$net/br-lan/brif"/*; do
		[ -e "$d" ] || continue
		p=${d##*/}
		case "$p" in
			lan*|wan*|eth*) ;;
			*) continue;;
		esac
		[ -e "$net/$p/carrier" ] || continue
		[ "$(cat "$net/$p/carrier" 2>/dev/null)" = "1" ] && echo "$p"
	done
	return 0
}

# 端口是否仍在 br-lan 的成员表里。
# "端口被整体摘出桥"的典型表现是：链路仍 UP、本机 IP 仍在、本机自检一切正常，
# 只有对端连不上 —— 必须查这个才验得出来。
mesh_brlan_has_port() {
	local net="${MESH_SYS_NET:-/sys/class/net}"
	[ -e "$net/br-lan/brif/$1" ]
}

# "端口内网化"自检时 br-lan 应该有哪些成员：全部内网物理端口（主节点保留的 WAN
# 上行口不在其中）+ 启用组网时的 bat0 —— bat0 是无线回程唯一的一层出口，
# 少了它无线侧完全不转发，却不会有任何报错（这正是最难查的一类故障）。
mesh_brlan_expected_members() {
	local p
	for p in $(mesh_lan_ports); do printf '%s\n' "$p"; done
	if [ "$(mesh_uci_getd main.enabled 0)" = "1" ] \
	   && [ "$(mesh_uci_getd main.batman 1)" = "1" ]; then
		printf '%s\n' bat0
	fi
	return 0
}

# 允许并入内网 br-lan 的物理端口 = 全部物理端口 - WAN 上行口
# 子节点已经走过 mesh_uci_remove_upstream()，所有上行/旁路接口都删干净了，
# 因此这里等于"全部物理端口"（即需求里的"所有端口都设成内网口"）；
# 主节点保留 WAN 上行口，这里才会真正排除掉它。
mesh_lan_ports() {
	local p w wdevs out="" skip
	wdevs=" $(mesh_wan_devices) "
	for p in $(mesh_all_physical_ports); do
		skip=0
		for w in $wdevs; do
			[ "$w" = "$p" ] && skip=1 && break
			# eth0.2 属于 eth0 的 VLAN 子接口：上行口是 eth0.2 时不要连带把 eth0 也算进去
			case "$p" in "$w".*) skip=1; break;; esac
			case "$w" in "$p".*) skip=1; break;; esac
		done
		[ "$skip" = "0" ] && out="$out $p"
	done
	echo "$out" | tr -s ' '
}

# 承载 br-lan 的 UCI 节（DSA 是 device 节，老配置是 lan 接口上的 bridge）
mesh_brlan_section() {
	local sec want
	want=$(uci -q get network.lan.device 2>/dev/null)
	for sec in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.]*\)=device$/\1/p'); do
		# ① device 节用 name 选项声明 br-lan（现代 DSA 默认写法；节名本身是匿名节名）
		[ "$(uci -q get "network.$sec.name" 2>/dev/null)" = "br-lan" ] && { echo "$sec"; return 0; }
		# ② device 节省略 name 时 netifd 拿节名当设备名 —— 节名恰好就是 br-lan
		if [ "$sec" = "br-lan" ]; then echo "$sec"; return 0; fi
		# ③ 节名恰好是 lan 接口 device 指向的设备名。必须再确认它确实是个桥：
		#    否则 `config device 'eth0'`（只写 macaddr）会被误认成 br-lan，
		#    接着往它身上写 ports —— netifd 会去建一个叫 eth0 的桥。
		if [ -n "$want" ] && [ "$sec" = "$want" ] && mesh_section_is_bridge "$sec"; then
			echo "$sec"; return 0
		fi
	done
	# ④ 老式：桥直接写在 lan 接口上（option type 'bridge'，成员在 ifname）
	[ "$(uci -q get network.lan.type 2>/dev/null)" = "bridge" ] && echo lan
}

# 把内网端口从**其它**网桥里摘出来 —— 兼容不同固件的关键一步。
# 一个 netdev 只能是一个 bridge 的成员。有些固件（尤其是给 WAN 单独建桥的）会在
# UCI 里留一个 br-wan：删掉 network.wan 这个**接口**并不会连带删掉 br-wan 这个
# **device 节**，于是 wan 口仍挂在它上面。此时直接 add_list 到 br-lan 会静默失败，
# 表现为"wan 口怎么都进不了内网"、且日志里毫无异常。
# 摘完之后若那个桥已经没有成员，就把整个节删掉 —— 留一个空桥会让 netifd 反复报错。
#
# 注意两点：① 其它桥可能是 device 节（成员在 ports），也可能是老式写在 interface
# 节上的桥（成员在 ifname），选项名必须按节类型取，写错就是"摘了个寂寞"；
# ② device 节不写 type 时 netifd 也按桥处理，所以不能只认 type=bridge。
mesh_uci_detach_other_bridges() {
	local brsec="$1" p sec opt ports left
	[ -n "$brsec" ] || return 0
	for sec in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=.*$/\1/p'); do
		[ "$sec" = "$brsec" ] && continue
		mesh_section_is_bridge "$sec" || continue
		opt=$(mesh_section_members_opt "$sec")
		ports=$(uci -q get "network.$sec.$opt" 2>/dev/null)
		[ -n "$ports" ] || continue
		for p in $(mesh_lan_ports); do
			mesh_has "$p" "$ports" || continue
			uci del_list "network.$sec.$opt=$p" 2>/dev/null
			mesh_log info "端口 $p 原属 $sec，已摘除以便并入 br-lan"
		done
		left=$(uci -q get "network.$sec.$opt" 2>/dev/null)
		if [ -z "$(printf '%s' "$left" | tr -d ' ')" ]; then
			uci -q delete "network.$sec" 2>/dev/null
			mesh_log info "网桥 $sec 已无成员，一并删除"
		fi
	done
	return 0
}

mesh_ports_into_brlan() {
	local sec="" opt p existing
	sec=$(mesh_brlan_section)
	if [ -z "$sec" ]; then
		mesh_log warn "未找到 br-lan 网桥，跳过端口并入"
		return 1
	fi
	# 先把端口从别的桥里摘出来，再往 br-lan 里加（顺序不能反）
	mesh_uci_detach_other_bridges "$sec"
	# 成员选项名不能想当然：device 节 / 新式桥在 ports，老式把桥写在 interface 节上
	# （option type 'bridge'）时成员在 ifname 里。写错选项名 uci 不报错、只是静默
	# 不生效 —— 端口永远进不了内网，且日志里毫无异常。
	opt=$(mesh_section_members_opt "$sec")
	for p in $(mesh_lan_ports); do
		existing=$(uci -q get "network.$sec.$opt" 2>/dev/null)
		mesh_has "$p" "$existing" || uci add_list "network.$sec.$opt=$p"
	done
	return 0
}

# 把 br-lan 的 MAC 钉成**设备主 MAC**（eth0 的永久 MAC）。
#
# 为什么必须钉：netifd 给网桥选 MAC 是按"端口就绪顺序"来的，bat0 一旦先进网桥，
# 网桥 MAC 就变成 bat0 那个随机 MAC（实测子节点在一次 network reload 后从
# 2c:b2:1a:99:28:25 变成 8a:18:c9:f1:df:02）。网桥 MAC 会变有三个实际后果：
#   ① 子节点的内网地址由主节点 DHCP 分发，租约按 MAC 记账 → 每次重载都可能换一个
#      IP，用户在界面之外根本找不到自己的节点；
#   ② br-lan 的 IPv6 链路本地地址跟着变，而它是"节点失联时的最后一条救援通道"；
#   ③ BLA 用网桥 MAC 标识 backbone gateway，MAC 一变认领表就要重建，期间可能出现
#      短暂的重复帧/环路窗口。
# 钉成设备主 MAC 是最小改动：主节点本来就恰好等于它（等于无操作），子节点则从此
# 与"物理网口的 MAC"对齐 —— 也就是 apply 之前的老状态。
#
# 为什么写在**网桥所在的那一节**（DSA 下就是 `config device` 的 br-lan 节，由
# mesh_brlan_section() 定位），而不是写在 `config interface 'lan'` 上 —— 本机实测
# 过两种写法（netifd 2026.02.26~cbb83a18）：
#   · `network.lan.macaddr='2c:...'`          → reload 后 br-lan 的 MAC **纹丝不动**
#   · `network.@device[0].macaddr='2c:...'`   → reload 后 br-lan 的 MAC **立刻变成它**
# 源码也印证：interface.c 里没有任何 macaddr 处理代码，只有 device.c 定义
# (DEV_ATTR_MACADDR) 并在 bridge.c 里被消费 —— 接口级 macaddr 在这个 netifd 版本上
# 是个"写了不报错、也不生效"的死选项。老式把桥直接写在 lan 接口上的配置，
# mesh_brlan_section() 返回的就是 lan，此处同样写到那一节（老 netifd 认它）。
mesh_pin_brlan_mac() {
	local sec mac
	sec=$(mesh_brlan_section)
	[ -n "$sec" ] || return 0
	mac=$(mesh_primary_mac)
	[ -n "$mac" ] || return 0
	[ "$(uci -q get "network.$sec.macaddr" 2>/dev/null)" = "$mac" ] || \
		uci set "network.$sec.macaddr=$mac"
	return 0
}

# ---------------- br-lan 转发表（＝真实承载链路） ----------------
# 输出 TSV: MAC|出口接口名，只含"从别的设备学到"的条目（is local? = no）。
#
# 为什么必须读转发表、而不是问了 batman-adv 就算数：
#   batman-adv 的 originator 表只认得 bat0 的 **hardif**。B 方案下 bat0 只有无线
#   mesh0 一个 hardif，网线是 br-lan 的桥端口 —— 它根本不是 batman 的一条"路径"。
#   于是 originators 的 outgoingIF 恒为 mesh0，"优先链路"无论插不插网线都会显示
#   无线，纯属误导（本包 v1.0.0-r5 及以前的状态页就是这么显示的）。
#   内核桥转发表才是答案：单播帧的**源** MAC 从哪个口学到，之后发往该 MAC 的帧就
#   从哪个口出 —— 那才是实际承载链路。
#
# 端口号必须用 `brctl showstp` 里的 port_no 对照，**不能按 brif 目录的枚举顺序猜**
# （两者顺序常不一致，会得出反向结论）。设备上没有 `bridge` 命令（iproute2 未带
# bridge 子命令），只有 brctl；brctl 不可用时本函数输出为空，调用方按"未知"降级。
mesh_brlan_fdb_tsv() {
	{ brctl showstp br-lan 2>/dev/null
	  echo "===MESH-FDB-SPLIT==="
	  brctl showmacs br-lan 2>/dev/null
	} 2>/dev/null | awk -v mark="===MESH-FDB-SPLIT===" '
		# 注意：变量名不能叫 split —— 那是 awk 的内建函数名，用它当变量会直接语法报错
		$0 == mark { macs = 1; hdr = 0; next }
		macs == 0 {
			# 端口名行形如 "lan1 (1)" / "bat0 (4)"，无前导空白；属性行有缩进
			if ($0 ~ /^[^ \t]/ && $0 ~ /\([0-9]+\)/) {
				name = $1
				pn = $2; gsub(/[()]/, "", pn)
				if (pn != "") P[pn] = name
			}
			next
		}
		{ if (hdr++ == 0) next }          # 跳过 "port no  mac addr ..." 表头
		$3 == "no" { ifn = P[$1]; if (ifn != "") printf "%s|%s\n", toupper($2), ifn }
	'
}

# 用于状态页「端口内网化」：主节点保留的 WAN 上行口不算"未并入"，
# 其余全部内网端口都必须在 br-lan 的成员表里（B 方案下端口就是直接进 br-lan 的）
mesh_all_ports_in_lan() {
	local p sec opt existing net live=0 role
	sec=$(mesh_brlan_section)
	[ -n "$sec" ] || return 1
	opt=$(mesh_section_members_opt "$sec")
	existing=$(uci -q get "network.$sec.$opt" 2>/dev/null)
	[ -n "$existing" ] || return 1
	# 运行时复核：只查 UCI 是不够的 —— 出现过"写进了 device 节不认的选项名、
	# UCI 看着齐全、实际 br-lan 里一个成员都没有"却报绿的情况（配置与自检读了
	# 同一个错选项，互相印证出假象）。这里用 brif 目录复核真实成员关系 ——
	# bridge 的成员关系是立即生效的（不像转发要等 STP 收敛），不会因收敛抖动。
	# br-lan 还没起来时退回只看配置。
	net="${MESH_SYS_NET:-/sys/class/net}"
	[ -d "$net/br-lan/brif" ] && live=1

	# ★ 主节点是另一把尺子：「全部物理端口并入内网」这个需求对它根本不适用 ——
	#   它必须保留上行口（这几台的上行是 pon0 光口，另有 lan1 当第二上行），
	#   没被任何接口用上的空闲口（实测 lan2）也不该算"未并入"。拿子节点的尺子
	#   量主节点，结果就是它永远挂红告警（2026-10-05 真机）。
	#   所以主节点只校验 bat0 真的挂进了 br-lan —— 那是它参与二层域的唯一条件。
	role=$(mesh_uci_get main.role)
	if [ "$role" = master ]; then
		[ "$(mesh_uci_getd main.batman 1)" = "1" ] || return 0
		mesh_has bat0 "$existing" || return 1
		[ "$live" = 1 ] && { mesh_brlan_has_port bat0 || return 1; }
		return 0
	fi

	for p in $(mesh_brlan_expected_members); do
		mesh_has "$p" "$existing" || return 1
		if [ "$live" = 1 ] && ! mesh_brlan_has_port "$p"; then return 1; fi
	done
	return 0
}

# 端口内网化体检明细（诊断页用）：期望 / 配置 / 运行时三份对比 + 缺失清单。
# 出问题时这里能一眼看出是"没写进配置"还是"写了但内核里没生效"。
mesh_brlan_members_report() {
	local sec opt existing p net live=0 miss="" role
	sec=$(mesh_brlan_section)
	opt=$(mesh_section_members_opt "$sec")
	existing=$(uci -q get "network.$sec.$opt" 2>/dev/null)
	role=$(mesh_uci_get main.role)
	net="${MESH_SYS_NET:-/sys/class/net}"
	[ -d "$net/br-lan/brif" ] && live=1
	echo "br-lan 节        = ${sec:-未找到}"
	echo "成员选项        = $opt"
	echo "本节点角色      = ${role:-未设置}"
	if [ "$role" = master ]; then
		echo "判定口径        = 主节点不适用「全端口内网化」，本页只校验 bat0"
	fi
	echo "期望成员        = $(mesh_brlan_expected_members | tr '\n' ' ')"
	echo "配置里的成员    = $(printf '%s\n' "$existing" | tr '\n' ' ')"
	echo "运行时成员      = $(ls "$net/br-lan/brif" 2>/dev/null | tr '\n' ' ')"
	echo "有载波的内网成员= $(mesh_brlan_carrier_ports | tr '\n' ' ')"
	echo "物理端口枚举    = $(mesh_all_physical_ports)"
	echo "上行口(应排除)  = $(mesh_wan_devices)"
	for p in $(mesh_brlan_expected_members); do
		mesh_has "$p" "$existing" || miss="$miss $p(未写入配置)"
		if [ "$live" = 1 ] && ! mesh_brlan_has_port "$p"; then miss="$miss $p(未挂到 br-lan)"; fi
	done
	if [ -n "$miss" ]; then echo "缺失            =$miss"; else echo "缺失            = 无"; fi
	return 0
}

# ---------------- 备份 / 还原 ----------------
mesh_backup_once() {
	# ★ "有备份就不刷新"会让还原点停在很久以前（r41）。
	#   真机 .219 的备份就停在两天前 —— 那时退出组网，会把用户后来改的 WiFi 名称
	#   密码、防火墙、DHCP 全部退回去。改成：**未入网时就重建**，在网时才保留。
	#   未入网 = 配置天然干净（没有 mesh 回程段 / 配对 AP / bat0），这时重建绝不会
	#   把组网状态固化进备份；在网时想刷新请用 mesh_backup_refresh（它先净化再写）。
	[ -d "$MESH_BACKUP_DIR/config" ] && [ "$(mesh_uci_getd main.enabled 0)" = "1" ] && return 0
	# 未入网（或还没有备份）：重建。先清空旧目录，避免留下上次多出来的文件。
	rm -rf "$MESH_BACKUP_DIR/config"
	mkdir -p "$MESH_BACKUP_DIR/config"
	local f
	# mesh 也备份：用户在组网前调过的按键档位、TTL、配对参数都在这里，
	# 还原时应该跟着回来（否则"退出组网"会顺手把用户的个人设置也抹掉）。
	# ★ 但它不能原样还原 —— 见 mesh_do_revert 里的清洗步骤。
	for f in wireless network dhcp firewall mesh; do
		[ -f "/etc/config/$f" ] && cp -a "/etc/config/$f" "$MESH_BACKUP_DIR/config/$f"
	done
	date '+%Y-%m-%d %H:%M:%S' > "$MESH_BACKUP_DIR/created"
	mesh_log info "已创建组网前配置备份: $MESH_BACKUP_DIR/config"
}

mesh_do_revert() {
	local f
	if [ ! -d "$MESH_BACKUP_DIR/config" ]; then
		mesh_log warn "未找到组网前备份"
		return 1
	fi
	for f in wireless network dhcp firewall mesh; do
		[ -f "$MESH_BACKUP_DIR/config/$f" ] && cp -a "$MESH_BACKUP_DIR/config/$f" "/etc/config/$f"
	done
	# ★ /etc/config/mesh 不能整份照搬回来：备份是在 apply 时做的，那一刻本机
	#   已经拿到（或派生好）凭证了，备份里必然带着 mesh_id / mesh_key /
	#   master_addr 这些"主节点信息"。原样还原的后果就是：网络其实已经退干净了，
	#   界面上却还显示着 Mesh ID、主节点地址和"子节点"身份（真机 .219 就是这样
	#   留下残影的，用户以为是"没退干净"）。所以先还原（保住用户自己调过的
	#   档位 / TTL / 配对参数），再把凭证类字段清空，让本机回到"从未入网"的状态。
	uci set mesh.main.enabled=0
	uci set mesh.main.status_text='已还原组网前配置（请先选择本节点角色）'
	uci set mesh.main.mesh_id=''
	uci set mesh.main.mesh_key=''
	uci set mesh.main.master_addr=''
	# ★ role 也要清（r41）。残留 client 的后果最严重：下次这台机器想当主节点时，
	#   apply 会直接走子节点分支 —— 删掉 wan 接口、把 WAN 口并进 br-lan、LAN 改 DHCP，
	#   而它本该是出口。这是静默发生的，不报错。清空的代价只是下次组网要多点一下
	#   选角色（状态页就能选），比踩坑划算。
	uci set mesh.main.role=''
	uci commit mesh
	# ★ 备份可能是在"已经组上网 / 已经开过窗"的状态下建的（老版本建备份时没做净化），
	#   整份拷回来会把 mesh 回程段和配对 AP 段一起带回来 —— 配对 AP 会重新长期广播
	#   （公开密码、桥进内网）。所以还原后按**内容**再清一遍：只认 mode=mesh 和
	#   配对 AP 的特征，不认段名，这样 r39 之前的匿名段 / wifinetN 也照样能清掉。
	#   网络侧不用清：实测三台的 network 备份都不含 bat0 / batmesh，整份覆盖回去
	#   本来就是干净的。
	#   注意顺序：这里的删除必须在下面的 wifi reload 之前完成。
	local sec victims=""
	for sec in $(mesh_wifi_ifaces); do
		[ "$(uci -q get "wireless.$sec.mode" 2>/dev/null)" = "mesh" ] && victims="$victims $sec"
	done
	victims="$victims $(mesh_pair_ap_sections 2>/dev/null)"
	for sec in $victims; do
		uci -q delete "wireless.$sec" 2>/dev/null
	done
	[ -n "$victims" ] && uci commit wireless
	rm -rf "$MESH_STATE_DIR"
	rm -f "$MESH_TMP_DIR"/lastok "$MESH_TMP_DIR"/lastfail "$MESH_TMP_DIR"/failreason "$MESH_TMP_DIR"/registry.tsv
	mesh_log info "已还原组网前配置（备份于 $(cat "$MESH_BACKUP_DIR/created" 2>/dev/null)）"
	# 备份已完成使命：删掉它。既回收闪存，也让下次 apply 重新备份"当时的组网前配置"。
	# 否则 revert → 再 apply 时用的仍是当初那份（可能已过时的）备份，还原点会错位。
	rm -rf "$MESH_BACKUP_DIR"
	# ★ 还原后的生效方式：以前是**无条件整机 reboot**，理由是"比逐个 restart 更彻底"。
	#   但光口机型整机重启的代价太大 —— 要重做 SerDes 初始化 + O1~O5 注册，几十秒到
	#   几分钟没有上行；而触发回滚的只是"管理地址没回来"，绝大多数情况重载配置就够了。
	#   改成逐项重载 + 校验：地址真回来了就不重启，确认起不来才兜底 reboot。
	#   后台延迟 2 秒执行，先让本进程把成功结果返回前端，避免 rpcd 调用因连接中断
	#   而误报失败（这与原来 reboot 的后台化是同一个理由）。
	( sleep 2; sync; mesh_net_revert_apply ) &
	return 0
}

# 还原后让配置生效：network 走增量 reload（不碰光口），无线 / 防火墙 / DHCP 逐个重载，
# 最后校验管理地址是否回来 —— 只有确实没起来才兜底重启路由器。
mesh_net_revert_apply() {
	local i want hit=0
	ubus call network reload >/dev/null 2>&1
	[ -x /sbin/wifi ] && wifi reload >/dev/null 2>&1
	[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload >/dev/null 2>&1
	[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1
	# 最多等 30 秒：br-lan 要重新收敛（STP forward_delay + DHCP 往返都要时间）
	for i in 1 2 3 4 5 6; do
		sleep 5
		want=$(uci -q get network.lan.ipaddr 2>/dev/null); want=${want%%/*}
		if [ -n "$want" ]; then
			ip -4 addr show dev br-lan 2>/dev/null | grep -q "inet $want/" && { hit=1; break; }
		else
			ip -4 addr show dev br-lan 2>/dev/null | grep -q 'inet ' && { hit=1; break; }
		fi
	done
	if [ "$hit" = 1 ]; then
		mesh_log info "还原后管理地址已恢复，未重启路由器"
		return 0
	fi
	mesh_log warn "还原后管理地址仍不可达，兜底重启路由器"
	reboot
	return 0
}

# 手动刷新备份（r41）：以**当前配置**为底，剔除组网相关内容后覆盖"组网前备份"。
# 与 mesh_backup_once 的分工：那个只在未入网时才建 / 重建，在网时一律不动；
# 这个由用户在维护页主动触发，解决"长期在网 → 还原点停在很久以前"的问题。
# ★ 安全设计：
#   ① 先复制到临时目录净化，净化失败也绝不会动到真实备份；
#   ② 覆盖前把旧备份留一份到 /etc/mesh-backup.prev，刷新后可退回；
#   ③ 净化的对象不只是"现在正在用的组网配置"，还包括老版本建备份时夹带进来的
#      残留（匿名段 / wifinetN），所以一律按**内容**认定，不认段名前缀。
# ⚠ 红线：全程只用 uci delete / del_list，**绝不 uci set 任何 ipaddr** ——
#   这台固件是 list ipaddr 'x/24' 写法，uci set 会写掉 /24 前缀导致整机失联。
mesh_backup_refresh() {
	local tmp="$MESH_TMP_DIR/backup-refresh"
	local f sec victims="" idx n avail
	mkdir -p "$MESH_TMP_DIR" 2>/dev/null
	rm -rf "$tmp"; mkdir -p "$tmp"
	# 闪存余量检查：实测单份备份 24KB，这里要求至少留 256KB
	avail=$(df -k /etc 2>/dev/null | awk 'NR==2 {print $4}')
	if [ -n "$avail" ] && [ "$avail" -lt 256 ]; then
		mesh_log warn "闪存剩余不足 256KB，放弃刷新备份"
		rm -rf "$tmp"
		return 1
	fi
	for f in wireless network dhcp firewall mesh; do
		[ -f "/etc/config/$f" ] && cp -a "/etc/config/$f" "$tmp/$f"
	done
	# ---- 在临时副本上净化（uci -c 指向副本，真实配置全程未被触碰）----
	# ① wireless：删 mesh 回程段
	for sec in $(uci -c "$tmp" -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
		[ "$(uci -c "$tmp" -q get "wireless.$sec.mode" 2>/dev/null)" = "mesh" ] && victims="$victims $sec"
	done
	# ② wireless：删配对 AP 段（副本段名与真实配置一致，直接用认出来的名字）
	for sec in $(mesh_pair_ap_sections 2>/dev/null); do
		victims="$victims $sec"
	done
	for sec in $victims; do
		uci -c "$tmp" -q delete "wireless.$sec" 2>/dev/null
	done
	uci -c "$tmp" commit wireless 2>/dev/null
	# ③ network：删 bat0 / batmesh 接口，并把 bat0 从 br-lan 的桥成员里摘掉
	uci -c "$tmp" -q delete network.bat0 2>/dev/null
	uci -c "$tmp" -q delete network.batmesh 2>/dev/null
	n=$(uci -c "$tmp" -q show network 2>/dev/null | grep -c '=device')
	idx=0
	while [ "$idx" -lt "${n:-0}" ]; do
		[ "$(uci -c "$tmp" -q get "network.@device[$idx].name" 2>/dev/null)" = "br-lan" ] &&
			uci -c "$tmp" -q del_list "network.@device[$idx].ports"='bat0' 2>/dev/null
		idx=$((idx+1))
	done
	uci -c "$tmp" commit network 2>/dev/null
	# ④ mesh：只清凭证与角色，保留按键档位 / TTL / 配对参数 / 信道等个人设置
	if [ -f "$tmp/mesh" ]; then
		uci -c "$tmp" -q set mesh.main.enabled=0
		uci -c "$tmp" -q set mesh.main.role=''
		uci -c "$tmp" -q set mesh.main.mesh_id=''
		uci -c "$tmp" -q set mesh.main.mesh_key=''
		uci -c "$tmp" -q set mesh.main.master_addr=''
		uci -c "$tmp" -q set mesh.main.status_text=''
		uci -c "$tmp" commit mesh 2>/dev/null
	fi
	# ---- 覆盖 ----
	rm -rf "$MESH_BACKUP_DIR.prev"
	[ -d "$MESH_BACKUP_DIR" ] && cp -a "$MESH_BACKUP_DIR" "$MESH_BACKUP_DIR.prev"
	rm -rf "$MESH_BACKUP_DIR"
	mkdir -p "$MESH_BACKUP_DIR/config"
	for f in wireless network dhcp firewall mesh; do
		[ -f "$tmp/$f" ] && cp -a "$tmp/$f" "$MESH_BACKUP_DIR/config/$f"
	done
	date '+%Y-%m-%d %H:%M:%S' > "$MESH_BACKUP_DIR/created"
	rm -rf "$tmp"
	mesh_log info "已刷新组网前配置备份（已剔除组网相关配置；旧备份留存于 $MESH_BACKUP_DIR.prev）"
	return 0
}


# ---------------- 回滚保护 ----------------
rollback_check() {
	local f="$MESH_STATE_DIR/rollback"
	[ -f "$f" ] || return 0
	local ip deadline now
	ip=$(sed -n 's/^ip=//p' "$f")
	deadline=$(sed -n 's/^deadline=//p' "$f")
	case "$deadline" in ''|*[!0-9]*) deadline=0;; esac
	if [ -f "$MESH_STATE_DIR/rollback.confirmed" ]; then
		rm -f "$f" "$MESH_STATE_DIR/rollback.confirmed"
		mesh_log info "用户已确认保留新管理地址 $ip"
		return 0
	fi
	now=$(date +%s)
	[ "$now" -lt "$deadline" ] && return 0
	# 到期：检查新地址是否仍挂在 br-lan 上（ip=- 表示 DHCP，只要有地址即视为可管理）
	# 注意 ip 取的是 uci network.lan.ipaddr 的**原值**，而某些固件（如 Kwrt）会把前缀
	# 直接写进这个值里（`list ipaddr '10.0.0.1/24'`）。此时再拼一个 "/" 就变成
	# "inet 10.0.0.1/24/" —— 一个永远匹配不到的模式：地址明明好好地挂在 br-lan 上，
	# 却被判成"不可达"，于是刚应用成功的组网被回滚窗口自动还原（实机踩到过）。
	# 这里先剥掉可能存在的前缀，两种写法都能正确判定。
	local hit want
	want="${ip%%/*}"
	if [ -z "$ip" ] || [ "$ip" = "-" ]; then
		hit=$(ip -4 addr show dev br-lan 2>/dev/null | grep -c 'inet ')
	else
		hit=$(ip -4 addr show dev br-lan 2>/dev/null | grep -c "inet $want/")
	fi
	if [ "${hit:-0}" -gt 0 ]; then
		rm -f "$f"
		mesh_log info "回滚窗口到期：管理地址 ${ip:-DHCP} 可达，配置保留"
	else
		mesh_log warn "回滚窗口到期：管理地址 ${ip:-DHCP} 不可达，自动还原组网前配置"
		mesh_do_revert
	fi
}

# ---------------- 服务 ----------------
mesh_ensure_service() {
	[ -x /etc/init.d/mesh ] || return 0
	/etc/init.d/mesh enabled >/dev/null 2>&1 || /etc/init.d/mesh enable
	pgrep -f 'meshctl daemon' >/dev/null 2>&1 || /etc/init.d/mesh start >/dev/null 2>&1
}
