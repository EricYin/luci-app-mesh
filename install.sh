#!/bin/sh
# luci-app-mesh 免编译安装脚本（直接复制到运行中的 OpenWrt）
# 用法: 在 OpenWrt 上执行  sh install.sh
#
# ★ 文件清单改为读 MANIFEST（单一真相源），不再在脚本里逐个写死。
#   此前脚本与 Makefile 各维护一份清单，本脚本长期漏装 3 个文件
#   （rc.wps/10-mesh 按键组网、uci-defaults/40-...、nginx conf），
#   走直装的机器上"按键一键组网"根本不存在。细节见 MANIFEST 顶部注释。
#
# 注：在线安装 / 升级 / 卸载请用 mesh-install.sh；本脚本只负责"把目录里的
#     文件按清单装好"，mesh-install.sh 的源码通道也是解包后调用本脚本。
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SRC/MANIFEST" ] || { echo "错误：请在项目目录中运行（缺少 MANIFEST）"; exit 1; }
[ -f "$SRC/root/usr/sbin/meshctl" ] || { echo "错误：请在项目目录中运行"; exit 1; }

echo "==> 按 MANIFEST 安装文件"
# ★ 先停守护进程：/usr/sbin/meshctl 带 shebang，内核以 execve 方式执行它，
#   进程在跑时覆盖该文件会 ETXTBSY（Text file busy）。装完在末尾 restart。
if [ -x /etc/init.d/mesh ]; then
	/etc/init.d/mesh stop >/dev/null 2>&1 || true
fi
INSTALLED=0
SKIPPED=0
# IFS='|' 逐字段读：源路径 | 目标路径 | 权限
while IFS='|' read -r src dst mode; do
	case "$src" in
		''|'#'*) continue ;;
	esac
	[ -n "$dst" ] && [ -n "$mode" ] || continue
	# /etc/config/mesh 是活配置：已存在就必须保留（升级语义由包管理器/卸载脚本负责）
	if [ "$dst" = "/etc/config/mesh" ] && [ -f /etc/config/mesh ]; then
		echo "    $dst 已存在，保留现有配置"
		SKIPPED=$((SKIPPED + 1))
		continue
	fi
	[ -f "$SRC/$src" ] || { echo "错误：MANIFEST 里声明的文件不存在: $src"; exit 1; }
	# ★ 不用 install 命令：目标固件的 busybox 没编进 install 这个小程序
	#   （三台实测 `command -v install` 全部为空），必须用 cp + chmod 代替。
	#   原写法 install -d/-m 在这些机器上会直接 "install: not found"。
	mkdir -p "$(dirname "$dst")"
	cp -f "$SRC/$src" "$dst" || { echo "错误：写入失败 $dst"; exit 1; }
	chmod "$mode" "$dst"
	INSTALLED=$((INSTALLED + 1))
done < "$SRC/MANIFEST"
echo "    已安装 $INSTALLED 个文件（跳过 $SKIPPED 个）"

echo "==> 清理旧版 Lua 界面（若存在）"
rm -f /usr/lib/lua/luci/controller/mesh.lua /usr/lib/lua/luci/view/mesh/*.htm \
      /usr/lib/lua/luci/model/cbi/mesh/settings.lua 2>/dev/null || true
rmdir /usr/lib/lua/luci/view/mesh /usr/lib/lua/luci/model/cbi/mesh 2>/dev/null || true

echo "==> 检查依赖（仅提示）"
MISSING=""

# 已安装包名列表（每行一个）。
# 包管理器兼容：OpenWrt 25.12+ 起用 apk 取代 opkg，固件里可能根本没有 opkg 命令。
# 这里直接读包数据库文件（比调 CLI 快，也免 fork）：
#   apk : /lib/apk/db/installed —— 每段以 P:<name> 开头
#   opkg: /usr/lib/opkg/status  —— 每段以 Package: <name> 开头
pkg_names() {
	if [ -r /lib/apk/db/installed ]; then
		sed -n 's/^P://p' /lib/apk/db/installed 2>/dev/null
	elif [ -r /usr/lib/opkg/status ]; then
		sed -n 's/^Package: *//p' /usr/lib/opkg/status 2>/dev/null
	elif command -v apk >/dev/null 2>&1; then
		apk info 2>/dev/null
	elif command -v opkg >/dev/null 2>&1; then
		opkg list-installed 2>/dev/null | awk '{print $1}'
	fi
	return 0
}

# 缺什么包时给出的安装命令（按实际包管理器给出，别让 apk 系统的用户去敲 opkg）
PM_HINT="opkg update && opkg install"
if command -v apk >/dev/null 2>&1 || [ -r /lib/apk/db/installed ]; then
	PM_HINT="apk update && apk add"
fi

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || MISSING="$MISSING curl/wget"
command -v jsonfilter >/dev/null 2>&1 || MISSING="$MISSING jsonfilter"
# 支持 802.11s 的 wpad 变体：wpad / wpad-openssl/wolfssl/mbedtls / wpad-mesh-*
# 只有 wpad-basic* / wpad-mini 不带 mesh 支持。两处坑都要避开：
#  1) 不能用 `A && B && C` 短路链：set -e 下这条链一旦整体返回非 0，
#     脚本会当场退出，后面的 rpcd 重启 / 服务启用 / 缓存清理全被跳过
#  2) `grep -vc` 在"一个都没匹配到"时输出 0 但退出码是 1 —— 直接放进
#     `var=$(...)` 同样会让 set -e 终止脚本。必须补 `|| true`
wpad_ok=$(pkg_names | sed -n '/^wpad/p' | grep -vc 'wpad-basic\|wpad-mini' || true)
[ "${wpad_ok:-0}" -gt 0 ] || MISSING="$MISSING wpad(支持802.11s的版本)"
# batman-adv 视为默认组件：缺了就提示安装（界面会自动隐藏相关选项，但组网仍可跑）
if [ -d /sys/module/batman_adv ] || command -v batctl >/dev/null 2>&1; then
	echo "    batman-adv: 已就绪"
else
	BAT_KMOD=""
	# 通配符不匹配时 $f 会是字面量字符串；用 if 显式判断，
	# 避免 for 体内的短路失败在 set -e 下把脚本带崩
	for f in /lib/modules/*/batman-adv.ko*; do
		if [ -e "$f" ]; then BAT_KMOD=1; break; fi
	done
	if [ -n "$BAT_KMOD" ]; then
		# 模块装了但没加载，启动时会自动 modprobe；这里先主动加载一次
		modprobe batman-adv 2>/dev/null || true
		command -v batctl >/dev/null 2>&1 || MISSING="$MISSING batctl"
	else
		MISSING="$MISSING kmod-batman-adv batctl"
	fi
fi
if [ -n "$MISSING" ]; then
	echo "    缺少:$MISSING —— 安装: $PM_HINT wpad-openssl curl jsonfilter kmod-batman-adv batctl"
fi
# batman-adv 的能力判断以「内核模块 batman_adv 可加载」为准 —— batctl 只是用户态工具。
# 模块缺失时 bat0 根本建不起来，无线回程也就无从谈起（子节点会退化成只能靠网线）。
# 所以判断核心是模块，不是 batctl 是否存在。
bat_mod=""
# 通配符不匹配时 $f 是字面量字符串；用 if 显式判断，
# 避免 for 体内的短路失败在 set -e 下把脚本带崩
for f in /lib/modules/*/batman-adv.ko*; do
	if [ -e "$f" ]; then bat_mod=1; break; fi
done
if [ -d /sys/module/batman_adv ]; then
	echo "    batman-adv: 已就绪 —— 设置页「路径选择」可开启，开启后按 TQ 择优链路"
elif [ -n "$bat_mod" ]; then
	echo "    batman-adv: 内核模块已安装但本次未加载成功（可 modprobe batman-adv 后重试）"
else
	echo "    batman-adv: 内核模块缺失 —— 设置页会隐藏「路径选择」（组网仍可用 802.11s HWMP）"
	echo "               安装: $PM_HINT kmod-batman-adv batctl"
fi

echo "==> 重启 rpcd（注册 mesh ubus 对象）"
/etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd start >/dev/null 2>&1 || true

echo "==> 启用并启动服务"
/etc/init.d/mesh enable
/etc/init.d/mesh restart 2>/dev/null || true
# 漫游自检：开机自启 + 每分钟 cron 巡检。
# 脚本自带 mesh 守卫（/etc/config/mesh 的 enabled 必须为 1 才动作），所以此刻即便
# 用户还没启用组网，也不会被改无线配置；一旦启用组网，自愈立刻开始工作。
for s in 97-wifi-roaming 99-dawn-roaming; do
	/etc/init.d/$s enable >/dev/null 2>&1 || true
	/etc/init.d/$s cron_enable >/dev/null 2>&1 || true
done

echo "==> 清除 LuCI 缓存"
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true

echo
echo "安装完成。浏览器打开: http://<本机IP>/cgi-bin/luci/ → 网络 → Mesh 组网"
echo "（若菜单未出现，请强制刷新浏览器 Ctrl+F5；必要时重启 uhttpd: /etc/init.d/uhttpd restart）"
