#!/bin/sh
# luci-app-mesh —— 在线安装 / 升级 / 卸载
#
# 用法:
#   mesh-install.sh install    [选项]     首次安装
#   mesh-install.sh upgrade    [选项]     升级（默认保留配置）
#   mesh-install.sh uninstall  [选项]     卸载（默认保留配置）
#   mesh-install.sh info                  探测本机环境、已装版本、远端最新版本
#
# 选项:
#   --keep-config            保留配置（升级/卸载的默认行为）
#   --no-keep-config         不保留配置：升级即恢复出厂默认值，卸载连配置一起清
#   --from=<路径>            本地介质：.apk / .ipk / .tar.gz(源码包) / 项目目录
#   --src                    强制走源码通道（解包后调用包内 install.sh）
#   --ver=<1.0.0-r43>        指定版本；省略则用 latest
#   --channel=release|main   release=GitHub Release（默认），main=开发分支源码包
#   --mirror=<前缀>          下载镜像前缀，如 https://ghfast.top/ （整串拼在 URL 前）
#   --force                  版本相同也重装
#   --revert / --no-revert   卸载前是否先退出组网（默认：交互询问，非交互则跳过）
#   --yes                    非交互，所有询问取默认值
#
# ★ 通道策略（已定）：pkg 优先 —— 下 apk/ipk 交给包管理器装（可查可卸，
#   文件清单由 Makefile 单一维护）；依赖解析失败或无源时自动兜底到 src
#   （下源码 tar.gz，解包后调用包内 install.sh 逐项复制文件）。
#
# ★ 为什么要有 /usr/libexec/mesh/version：
#   包数据库的版本会撒谎 —— 真机上 apk 记的是随固件编进来的 1.0.0-r23，
#   实际文件早被手动覆盖成 r43，"要不要升级"因此根本判不准。该文件随每次
#   安装/升级被覆盖，永远等于当前落地文件的真实版本。
#
# ★ 卸载为什么要按内置清单再扫一遍残留：
#   同样是版本谎报的直接后果 —— apk del 按 r23 的旧清单删，r30 之后新增的
#   文件（如 /etc/rc.wps/10-mesh）它根本不认识。所以包管理器删完必须补扫。

set -e

REPO="xxosdev/luci-app-mesh"
PKGNAME="luci-app-mesh"
VERSION_FILE="/usr/libexec/mesh/version"
KEEP_DIR="/etc/mesh-config.keep"
WORK=""

# ★ 内置文件清单（卸载扫残留用，CI 会校验它与 MANIFEST 完全一致）。
# 为什么需要副本：卸载时包里的 MANIFEST 已经随包被删了，必须有本地一份。
BUILTIN_MANIFEST='
/usr/sbin/meshctl
/usr/sbin/mesh-install
/usr/libexec/mesh/functions.sh
/usr/libexec/mesh/version
/usr/libexec/rpcd/mesh
/etc/init.d/mesh
/etc/init.d/97-wifi-roaming
/etc/init.d/99-dawn-roaming
/etc/uci-defaults/40-luci-app-mesh-roaming
/etc/hotplug.d/iface/30-mesh-bat-mtu
/etc/rc.wps/10-mesh
/etc/config/mesh
/www/cgi-bin/mesh-sync
/etc/nginx/conf.d/mesh-sync.locations
/usr/share/luci/menu.d/luci-app-mesh.json
/usr/share/rpcd/acl.d/luci-app-mesh.json
/www/luci-static/resources/view/mesh/overview.js
/www/luci-static/resources/view/mesh/settings.js
/www/luci-static/resources/view/mesh/tools.js
/www/luci-static/resources/view/mesh/mesh.css
'

OPT_KEEP="default"
OPT_FROM=""
OPT_SRC=0
OPT_VER=""
OPT_CHANNEL="release"
OPT_MIRROR=""
OPT_FORCE=0
OPT_REVERT="ask"
OPT_YES=0

# ================= 小工具 =================
log()  { printf '%s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

cleanup() {
	# 注意：set -e 下 `[ -n x ] && rm` 这种裸 && 列表整体非 0 会终止脚本，
	# 清理函数必须写成 if（同理见 remove_residual）
	if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
	return 0
}
trap cleanup EXIT INT TERM

# 版本比较只看 -r 后面的数字（1.0.0-r43 -> 43）
ver_num() {
	local n
	n=${1##*-r}
	case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# 交互式 yes/no；非交互（--yes 或无 tty）时返回 $2
ask_yn() {
	local q="$1" def="$2" ans
	# ⚠ 内部不能裸写 `[ "$def" = y ]`：那在 def=n 时会让 set -e 当场终止脚本。
	# 一律显式 return 0/1，由调用处的 if 决定是否豁免。
	if [ "$OPT_YES" = 1 ]; then
		if [ "$def" = y ]; then return 0; fi
		return 1
	fi
	if [ ! -t 0 ]; then
		warn "非交互环境，按默认回答: $q -> $def"
		if [ "$def" = y ]; then return 0; fi
		return 1
	fi
	printf '%s [y/N]: ' "$q"
	read -r ans || ans=""
	case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ================= 环境探测 =================
detect_pm() {
	# 优先看数据库文件，再看命令 —— 固件可能只有其一
	if [ -r /lib/apk/db/installed ] || command -v apk >/dev/null 2>&1; then
		echo apk
	elif [ -r /usr/lib/opkg/status ] || command -v opkg >/dev/null 2>&1; then
		echo opkg
	else
		echo none
	fi
}

detect_arch() {
	local a
	a=$(sed -n 's/^OPENWRT_ARCH="\([^"]*\)"/\1/p' /etc/os-release 2>/dev/null || true)
	[ -n "$a" ] || a=$(uname -m 2>/dev/null || echo unknown)
	echo "$a"
}

# 真实版本：以随包落地的 version 文件为准
file_version() {
	[ -r "$VERSION_FILE" ] || return 0
	tr -d ' \t\r\n' < "$VERSION_FILE" 2>/dev/null || true
}

# 包数据库登记的版本（可能与真实版本不一致 —— 这正是要对比它的原因）
db_version() {
	local pm="$1" v=""
	if [ "$pm" = apk ]; then
		v=$(sed -n "/^P:${PKGNAME}\$/,/^\$/ s/^V://p" /lib/apk/db/installed 2>/dev/null | head -n 1)
	elif [ "$pm" = opkg ]; then
		v=$(awk -v p="$PKGNAME" '$1=="Package:"{f=($2==p)} f&&/^Version:/{print $2; exit}' /usr/lib/opkg/status 2>/dev/null)
	fi
	printf '%s' "${v:-}"
}

in_network() {
	[ "$(uci -q get mesh.main.enabled 2>/dev/null)" = "1" ] && [ -x /usr/sbin/meshctl ]
}

# 按内置清单统计已落地/缺失文件数
scan_files() {
	local present=0 missing=0 f
	for f in $BUILTIN_MANIFEST; do
		if [ -e "$f" ]; then present=$((present + 1)); else missing=$((missing + 1)); fi
	done
	echo "$present $missing"
}

# ================= 下载 =================
fetch() { # $1=url $2=dst
	local url="$1" dst="$2"
	[ -n "$url" ] || return 1
	rm -f "$dst"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 --max-time 240 -o "$dst" "$url" && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -O "$dst" "$url" && return 0
	fi
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$dst" "$url" && return 0
	fi
	return 1
}

gh_url() { # $1=asset 文件名
	local asset="$1" base
	if [ -n "$OPT_VER" ]; then
		base="https://github.com/$REPO/releases/download/v$OPT_VER/$asset"
	else
		base="https://github.com/$REPO/releases/latest/download/$asset"
	fi
	printf '%s%s' "$OPT_MIRROR" "$base"
}

# pkg 通道应下载的资产名：固定名副本（Release 上由 CI 额外上传一份）
pkg_asset() {
	local pm="$1"
	if [ "$pm" = apk ]; then echo "$PKGNAME.apk"; else echo "$PKGNAME.ipk"; fi
}

src_asset() { echo "$PKGNAME-src.tar.gz"; }

# ================= 安装动作 =================
post_install() {
	# 与 Makefile postinst / install.sh 收尾保持一致，全部幂等
	/etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd start >/dev/null 2>&1 || true
	if [ -x /etc/init.d/mesh ]; then
		/etc/init.d/mesh enable >/dev/null 2>&1 || true
		/etc/init.d/mesh restart >/dev/null 2>&1 || true
	fi
	for s in 97-wifi-roaming 99-dawn-roaming; do
		[ -x "/etc/init.d/$s" ] || continue
		"/etc/init.d/$s" enable >/dev/null 2>&1 || true
		"/etc/init.d/$s" cron_enable >/dev/null 2>&1 || true
	done
	rm -f /tmp/luci-indexcache* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
	return 0
}

# 提示升级后是否产生了新默认配置（说明本机配置被保留下来了）
hint_new_default() {
	local f
	for f in /etc/config/mesh.apk-new /etc/config/mesh-opkg; do
		[ -f "$f" ] || continue
		warn "检测到 $f：/etc/config/mesh 已按你的现有配置保留，包内新默认值放在这个文件里（可删除）"
	done
	return 0
}

install_from_pkg() { # $1=本地包文件 $2=pm
	local f="$1" pm="$2" rc=0
	log "==> 用 $pm 安装 $f"
	if [ "$pm" = apk ]; then
		if [ "$OPT_FORCE" = 1 ]; then
			apk add --allow-untrusted --force-overwrite "$f" || rc=$?
		else
			apk add --allow-untrusted "$f" || rc=$?
		fi
	else
		if [ "$OPT_FORCE" = 1 ]; then
			opkg install --force-reinstall "$f" || rc=$?
		else
			opkg install "$f" || rc=$?
		fi
	fi
	return $rc
}

install_from_src() { # $1=源码包或目录
	local src="$1" dir="$src" top
	if [ -f "$src" ]; then
		WORK=$(mktemp -d /tmp/mesh-inst.XXXXXX 2>/dev/null || echo /tmp/mesh-inst.$$)
		mkdir -p "$WORK"
		case "$src" in
			*.tar.gz|*.tgz) tar xzf "$src" -C "$WORK" || die "解包失败: $src" ;;
			*) die "不支持的本地介质: $src（支持 .apk / .ipk / .tar.gz / 项目目录）" ;;
		esac
		dir=""
		for d in "$WORK" "$WORK"/*; do
			if [ -f "$d/MANIFEST" ]; then dir="$d"; break; fi
		done
		[ -n "$dir" ] || die "解包后找不到 MANIFEST: $src"
	fi
	[ -f "$dir/MANIFEST" ] || die "不是有效的项目目录（缺少 MANIFEST）: $dir"
	log "==> 源码通道：按 MANIFEST 安装（$dir）"
	sh "$dir/install.sh" || die "install.sh 执行失败"
	return 0
}

# ================= 卸载 =================
stop_services() {
	if [ -x /etc/init.d/mesh ]; then
		/etc/init.d/mesh stop >/dev/null 2>&1 || true
		/etc/init.d/mesh disable >/dev/null 2>&1 || true
	fi
	# 必须在文件被删除**之前**清 cron 与自启链接，否则留下每分钟拉起不存在脚本的僵尸条目
	for s in 97-wifi-roaming 99-dawn-roaming; do
		[ -x "/etc/init.d/$s" ] || continue
		"/etc/init.d/$s" cron_disable >/dev/null 2>&1 || true
		"/etc/init.d/$s" disable >/dev/null 2>&1 || true
	done
	return 0
}

save_config() {
	mkdir -p "$KEEP_DIR" || die "无法创建 $KEEP_DIR"
	for f in /etc/config/mesh /etc/mesh-backup /etc/mesh-backup.prev /etc/mesh-state; do
		[ -e "$f" ] || continue
		cp -a "$f" "$KEEP_DIR/" 2>/dev/null || true
		log "    已留存 $f -> $KEEP_DIR/"
	done
	return 0
}

restore_config() {
	local n
	[ -d "$KEEP_DIR" ] || return 0
	for n in mesh mesh-backup mesh-backup.prev mesh-state; do
		[ -e "$KEEP_DIR/$n" ] || continue
		if [ "$n" = mesh ]; then
			cp -a "$KEEP_DIR/$n" /etc/config/mesh 2>/dev/null || true
			log "    已还原 /etc/config/mesh"
		else
			cp -a "$KEEP_DIR/$n" "/etc/$n" 2>/dev/null || true
			log "    已还原 /etc/$n"
		fi
	done
	return 0
}

# 包管理器删完再补扫：版本谎报时旧清单覆盖不到新增文件
remove_residual() {
	local f n=0
	for f in $BUILTIN_MANIFEST; do
		[ -e "$f" ] || continue
		rm -f "$f" 2>/dev/null || true
		n=$((n + 1))
	done
	rm -rf /etc/mesh-state 2>/dev/null || true
	rm -rf /tmp/mesh /tmp/mesh-apply.out 2>/dev/null || true
	if [ "$n" -gt 0 ]; then log "    补删残留文件 $n 个"; fi
	return 0
}

do_uninstall() {
	local pm cur
	pm=$(detect_pm)
	cur=$(file_version)
	log "==> 卸载 $PKGNAME${cur:+ （文件版本 $cur）}"

	# 1) 在网检测：直接卸载会留下"配置还在、meshctl 没了"的僵尸状态
	if in_network; then
		if [ "$OPT_REVERT" = yes ]; then
			log "==> 先退出组网（--revert）"
			/usr/sbin/meshctl revert >/dev/null 2>&1 || warn "退出组网未成功，继续卸载"
		elif [ "$OPT_REVERT" = no ]; then
			warn "本机仍在组网中，直接卸载会留下已生效的网络配置（--no-revert 已指定）"
		elif ask_yn "本机仍在组网中，卸载前是否先退出组网（还原配置）？" n; then
			log "==> 先退出组网"
			/usr/sbin/meshctl revert >/dev/null 2>&1 || warn "退出组网未成功，继续卸载"
		else
			warn "跳过退出组网：wireless/network 里的 xxmesh_* 配置段将保留但无人维护"
		fi
	fi

	# 2) 保留配置
	if [ "$OPT_KEEP" = no ]; then
		log "==> 不保留配置（--no-keep-config）"
		rm -rf /etc/config/mesh /etc/mesh-backup /etc/mesh-backup.prev /etc/mesh-state 2>/dev/null || true
	else
		log "==> 保留配置到 $KEEP_DIR"
		save_config
	fi

	# 3) 停服务 + 清 cron（必须在删文件之前）
	stop_services

	# 4) 包管理器卸载
	if [ "$pm" = apk ]; then
		apk del "$PKGNAME" >/dev/null 2>&1 || warn "apk del 未成功（可能未登记），继续按清单清理"
	elif [ "$pm" = opkg ]; then
		opkg remove "$PKGNAME" >/dev/null 2>&1 || warn "opkg remove 未成功（可能未登记），继续按清单清理"
	fi

	# 5) 补扫残留
	remove_residual

	# 6) 拷回配置
	if [ "$OPT_KEEP" != no ]; then
		log "==> 还原配置"
		restore_config
		log "    保留的配置在 $KEEP_DIR，确认无误后可自行删除该目录"
	fi

	# 7) 收尾
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	rm -f /tmp/luci-indexcache* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
	log "卸载完成。（菜单消失需 Ctrl+F5 强刷）"
	return 0
}

# ================= 安装 / 升级 =================
do_install() {
	local pm cur target
	pm=$(detect_pm)
	cur=$(file_version)
	if [ -n "$cur" ] && [ "$OPT_FORCE" != 1 ]; then
		die "已安装 $cur（如要重装请加 --force，如要升级请用 upgrade）"
	fi
	target=$(acquire "$pm") || die "获取安装包失败"
	apply_media "$target" "$pm"
	post_install
	log "安装完成（版本: $(file_version)）。浏览器打开: http://<本机IP>/cgi-bin/luci/ → 网络 → Mesh 组网"
	return 0
}

do_upgrade() {
	local pm cur target
	pm=$(detect_pm)
	cur=$(file_version)
	log "==> 当前版本: ${cur:-（未知）}  包管理器: $pm"
	if [ -n "$OPT_VER" ] && [ "$cur" = "$OPT_VER" ] && [ "$OPT_FORCE" != 1 ]; then
		log "已是目标版本 $OPT_VER（加 --force 可重装）"
		return 0
	fi

	# 不保留配置 = 回到出厂：清掉活配置，装完后即包内默认值
	# （mesh-backup / mesh-state 一并清，下次启用组网会重建还原点）
	if [ "$OPT_KEEP" = no ]; then
		if ask_yn "不保留配置：将删除 /etc/config/mesh、/etc/mesh-backup、/etc/mesh-state，确定？" n; then
			rm -rf /etc/config/mesh /etc/mesh-backup /etc/mesh-backup.prev /etc/mesh-state 2>/dev/null || true
			log "    已清除本机配置"
		else
			die "已取消（用户选择保留配置）"
		fi
	fi

	target=$(acquire "$pm") || die "获取安装包失败"
	apply_media "$target" "$pm"
	post_install
	hint_new_default
	log "升级完成（版本: $(file_version)）"
	return 0
}

# 取包：pkg 优先，失败兜底 src；返回本地文件路径
acquire() {
	local pm="$1" f url
	if [ -n "$OPT_FROM" ]; then
		printf '%s' "$OPT_FROM"; return 0
	fi
	if [ "$OPT_SRC" != 1 ] && [ "$pm" != none ]; then
		f="$WORK/$(pkg_asset "$pm")"
		if fetch "$(gh_url "$(pkg_asset "$pm")")" "$f" && [ -s "$f" ]; then
			check_sha "$f" || return 1
			printf '%s' "$f"; return 0
		fi
		warn "下载 $(pkg_asset "$pm") 失败，兜底改用源码通道"
	fi
	f="$WORK/luci-app-mesh-src.tar.gz"
	if [ "$OPT_CHANNEL" = main ]; then
		url="https://codeload.github.com/$REPO/tar.gz/refs/heads/main"
	else
		url=$(gh_url "$(src_asset)")
	fi
	fetch "$url" "$f" || return 1
	[ -s "$f" ] || return 1
	printf '%s' "$f"
}

# sha256 校验：best-effort —— Release 上没有 sha256sums.txt 就跳过（比如 CI 还没跑过），
# 但**只要下到了就必须比对**，不一致直接放弃（下载被劫持/截断时这是唯一防线）。
check_sha() {
	local f="$1" want got sums
	[ -f "$f" ] || return 0
	command -v sha256sum >/dev/null 2>&1 || return 0
	sums="$WORK/sha256sums.txt"
	fetch "$(gh_url sha256sums.txt)" "$sums" || return 0
	want=$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)[[:space:]][[:space:]]*.*${f##*/}\$#\\1#p" "$sums" 2>/dev/null | head -n 1)
	[ -n "$want" ] || return 0
	got=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
	if [ "$want" = "$got" ]; then
		log "    sha256 校验通过（${f##*/}）"
		return 0
	fi
	warn "sha256 不一致：期望 $want 实际 $got —— 已放弃安装"
	return 1
}

apply_media() { # $1=本地介质 $2=pm
	local m="$1" pm="$2"
	case "$m" in
		*.apk) install_from_pkg "$m" apk || die "apk 安装失败（依赖不满足或无源？可加 --src 走源码通道）" ;;
		*.ipk) install_from_pkg "$m" opkg || die "opkg 安装失败（依赖不满足或无源？可加 --src 走源码通道）" ;;
		*) install_from_src "$m" ;;
	esac
}

# ================= info =================
do_info() {
	local pm arch cur dbv scan p m
	pm=$(detect_pm); arch=$(detect_arch)
	cur=$(file_version); dbv=$(db_version "$pm")
	scan=$(scan_files); p=${scan%% *}; m=${scan##* }
	log "仓库:       https://github.com/$REPO"
	log "包管理器:   $pm"
	log "架构:       $arch"
	log "文件版本:   ${cur:-（未安装或无 version 文件）}"
	log "数据库版本: ${dbv:-（无记录）}"
	log "落地文件:   $p 个存在 / $m 个缺失"
	if [ -n "$dbv" ] && [ -n "$cur" ] && [ "$dbv" != "$cur" ]; then
		warn "版本不一致：包数据库记 $dbv，实际文件 $cur —— 卸载时包管理器会按旧清单删，务必靠本脚本补扫残留"
	fi
	if in_network; then log "组网状态:   已启用"; else log "组网状态:   未启用"; fi
	if [ -f /etc/mesh-backup/config/wireless ]; then
		log "还原点:     已创建（/etc/mesh-backup）"
	else
		log "还原点:     无"
	fi
	return 0
}

# ================= 入口 =================
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

CMD="${1:-}"
[ -n "$CMD" ] || { usage; exit 1; }
shift || true

for a in "$@"; do
	case "$a" in
		--keep-config)    OPT_KEEP=yes ;;
		--no-keep-config) OPT_KEEP=no ;;
		--src)            OPT_SRC=1 ;;
		--force)          OPT_FORCE=1 ;;
		--revert)         OPT_REVERT=yes ;;
		--no-revert)      OPT_REVERT=no ;;
		--yes|-y)         OPT_YES=1 ;;
		--from=*)         OPT_FROM=${a#--from=} ;;
		--ver=*)          OPT_VER=${a#--ver=} ;;
		--channel=*)      OPT_CHANNEL=${a#--channel=} ;;
		--mirror=*)       OPT_MIRROR=${a#--mirror=} ;;
		-h|--help)        usage; exit 0 ;;
		*)                die "未知参数: $a" ;;
	esac
done

# 默认值：keep-config 即默认行为（--keep-config 与不写等价）
[ "$OPT_KEEP" = default ] && OPT_KEEP=yes
[ "$OPT_CHANNEL" = main ] && OPT_SRC=1

if [ -n "$OPT_FROM" ] && [ ! -e "$OPT_FROM" ]; then
	die "--from 指定的路径不存在: $OPT_FROM"
fi

[ -n "$WORK" ] || WORK=$(mktemp -d /tmp/mesh-inst.XXXXXX 2>/dev/null || echo /tmp/mesh-inst.$$)
mkdir -p "$WORK"

case "$CMD" in
	install)   do_install ;;
	upgrade)   do_upgrade ;;
	uninstall) do_uninstall ;;
	info)      do_info ;;
	*)         usage; die "未知命令: $CMD" ;;
esac
