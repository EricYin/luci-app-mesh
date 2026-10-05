# luci-app-mesh — OpenWrt feed 打包
# 构建方法见 README.md

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mesh
PKG_VERSION:=1.0.0
PKG_RELEASE:=37
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Xx

LUCI_TITLE:=802.11s Mesh 组网管理（JS 界面 · 主/子节点 · 配置同步 · 信道错开 · 全端口内网化）
# ===== 前置条件补齐（2026-09-22，针对 K2P / mt7621 固定内核编译）=====
#   ① 802.11s 无线驱动支持: mesh point 能力由 mac80211 框架提供。K2P 的 mt76 驱动
#      默认已选中 kmod-mac80211，因此这一项**不列入** LUCI_DEPENDS —— 列上去会让
#      某些 target 因解析不到该包而整包装不上，得不偿失。
#   ② 完整版 wpad（非 wpad-basic / wpad-mini）: +wpad-mesh-openssl 提供 802.11s
#      mesh point 所需的完整 supplicant 能力（wpad-basic / wpad-mini 不带 mesh point）。
#   ③ batman-adv 内核支持（原按“可选增强”故意不写依赖）: +kmod-batman-adv +batctl。
#      此前为避免内核版本不匹配导致整包装不上而改为按需安装；现目标镜像内核固定，
#      故恢复为强依赖，确保“开箱即有 batman-adv 路径选择”。
#   ④ bat0 的 LuCI 协议支持: +luci-proto-batman-adv —— 让「网络 → 接口」里能直接
#      新建/编辑 batman-adv 协议（proto 'batadv'）的接口。缺它时 bat0 只能在命令行
#      配置，网页端不认这个协议。该包是纯 LuCI 前端（架构 all），无内核耦合，
#      官方 feeds 与目标固件源里均有提供，列入依赖是安全的。
#   ⑤ 无线漫游引导（802.11k/v 客户端引导): +dawn +umdns。
#      dawn 在各 AP 之间通过 umdns 交换客户端信号与负载，用 802.11k 邻居报告 +
#      802.11v BTM 引导客户端切到更优 AP（客户端不配合时才降级踢除）；只有 AP
#      侧强制，客户端无需装任何东西。dawn 自身已 DEPENDS +umdns，这里显式列出
#      是为了让"漫游能力"在包依赖里可见、也避免只装 dawn 而 umdns 未随包管理器
#      带出的边缘情况。两者都是架构 all 的用户态包，无内核耦合。
LUCI_DEPENDS:=+uclient-fetch +rpcd +curl +jsonfilter +iwinfo +iw \
	+wpad-mesh-openssl \
	+kmod-batman-adv +batctl +luci-proto-batman-adv \
	+dawn +umdns
LUCI_PKGARCH:=all

# 下面的 Package/install 已手动逐项安装并设置权限，这里的 PKG_INSTALL 仅作兜底
PKG_INSTALL:=$(CURDIR)/root

include $(TOPDIR)/feeds/luci/luci.mk

# 保留 root/ 下的目录结构与权限（cgi-bin 可执行位）
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(CURDIR)/root/usr/sbin/meshctl $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/usr/libexec/mesh
	$(INSTALL_DATA) $(CURDIR)/root/usr/libexec/mesh/functions.sh $(1)/usr/libexec/mesh/
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) $(CURDIR)/root/usr/libexec/rpcd/mesh $(1)/usr/libexec/rpcd/mesh
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/root/etc/init.d/mesh $(1)/etc/init.d/
# 无线漫游自检脚本：97 补齐 AP 的 802.11k/11v/11r，99 校正 dawn/umdns 的
# 广播地址与跨机参数。两者都是幂等的"差异修复器"，只在配置漂移时才落盘。
# 这里只负责装文件；enable + cron_enable 在 postinst，cron 清理在 prerm。
	$(INSTALL_BIN) $(CURDIR)/root/etc/init.d/97-wifi-roaming $(1)/etc/init.d/
	$(INSTALL_BIN) $(CURDIR)/root/etc/init.d/99-dawn-roaming $(1)/etc/init.d/
# 上面注释里说的"enable + cron_enable 在 postinst"，只对 opkg/apk **安装**生效。
# 把本包编译进 image（随固件预装）时没有安装钩子，postinst 一次都不会跑 —— 于是
# 两个自检脚本既可能没有自启链接、更一定没有 cron 条目，加上 97 的 start() 有
# mesh 守卫（新机首次开机 enabled 还是 0），那唯一一次机会也落空，此后永不再触发。
# 症状：802.11k/v/r 与 dawn 广播地址长期缺失，且 LuCI 无线页一保存就又被冲掉。
# uci-defaults 由 /etc/init.d/boot 在**首次开机**执行（成功即自删），是唯一能在
# "预装 + 首次启动"这个时间点做初始化的官方机制，用来把 postinst 欠下的补回来。
# 它内部同样只调脚本自带的 enable / cron_enable，保持单一真相源。
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/root/etc/uci-defaults/40-luci-app-mesh-roaming $(1)/etc/uci-defaults/
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) $(CURDIR)/root/etc/hotplug.d/iface/30-mesh-bat-mtu $(1)/etc/hotplug.d/iface/
# 按键一键组网：挂在系统 WPS 分发器 /etc/rc.button/wps 下（它遍历 /etc/rc.wps/*，
# 返回 0 即 break）。不备份也不覆盖任何系统文件，卸载时随包移除即可。
# 为什么要抢 WPS 键、档位怎么分、以及"为什么按住期间没有 LED 提示"，见脚本内注释。
	$(INSTALL_DIR) $(1)/etc/rc.wps
	$(INSTALL_BIN) $(CURDIR)/root/etc/rc.wps/10-mesh $(1)/etc/rc.wps/10-mesh
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) $(CURDIR)/root/etc/config/mesh $(1)/etc/config/
	$(INSTALL_DIR) $(1)/www/cgi-bin
	$(INSTALL_BIN) $(CURDIR)/root/www/cgi-bin/mesh-sync $(1)/www/cgi-bin/
# nginx + uwsgi 型固件(如 Kwrt)专用: 标准 OpenWrt 用 uhttpd，/cgi-bin/ 自动按 CGI 执行，
# 不需要本文件；没有 nginx 的机器上它不会被读取，属无害冗余。详见文件内注释。
	$(INSTALL_DIR) $(1)/etc/nginx/conf.d
	$(INSTALL_DATA) $(CURDIR)/root/etc/nginx/conf.d/mesh-sync.locations $(1)/etc/nginx/conf.d/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/luci/menu.d/luci-app-mesh.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/rpcd/acl.d/luci-app-mesh.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/mesh
	$(INSTALL_DATA) $(CURDIR)/htdocs/luci-static/resources/view/mesh/*.js $(1)/www/luci-static/resources/view/mesh/
	$(INSTALL_DATA) $(CURDIR)/htdocs/luci-static/resources/view/mesh/mesh.css $(1)/www/luci-static/resources/view/mesh/
endef

# /etc/config/mesh 必须声明为 conffile —— 少了这一句，opkg 会把它当普通文件、
# 每次 install/upgrade 都直接把用户的活配置换成包内默认值（实测踩到两次：
# mesh_id / mesh_key / role / enabled / 已填的主节点地址全丢，且不生成 -opkg 备份；
# 主节点 enabled 被换成 0 后 mesh-sync 停发，子节点报"无法从主节点获取配置"，
# 症状极像网络故障）。apk 那边因为默认保护 /etc 下已存在的文件（新默认落到
# mesh.apk-new）而看不出问题，所以这个坑只在 opkg 侧暴露。
# 声明后 opkg 的行为：用户改过 → 保留用户的、新默认落到 /etc/config/mesh-opkg；
# 没改过 → 直接更新。
define Package/$(PKG_NAME)/conffiles
/etc/config/mesh
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1
[ -x /etc/init.d/mesh ] && /etc/init.d/mesh enable >/dev/null 2>&1
# 无线漫游自检：默认开机自启 + 每分钟 cron 巡检自愈。
# 为什么默认就要开：本系列固件不发 procd 的 config.change 事件，而 LuCI 无线页保存
# 会重写整段 wireless、把 rrm_neighbor_report / rrm_beacon_report 这类项直接冲掉，
# 只能靠轮询补回来。脚本幂等，配置正常时一轮开销约等于一次 md5sum。
# 敢默认开的前提是脚本内部带 mesh 守卫（mesh.main.enabled 必须为 1 才动作），
# 所以普通路由模式下装了本包也不会被改无线配置。对应的 cron 清理在 prerm。
# 注：shell 变量在 Makefile 里要写 $$s，否则会被 make 当变量展开成空。
for s in 97-wifi-roaming 99-dawn-roaming; do
	[ -x "/etc/init.d/$$s" ] && "/etc/init.d/$$s" enable >/dev/null 2>&1
	[ -x "/etc/init.d/$$s" ] && "/etc/init.d/$$s" cron_enable >/dev/null 2>&1
done
# nginx + uwsgi 型固件(如 Kwrt): 装完立刻让 mesh-sync 的 location 生效。
# 仅在“确实有 nginx、且其配置真的 include conf.d/*.locations、且 uwsgi_params 存在”时才 reload，
# 避免在无关系统上做无意义的配置重载。reload 失败不会影响正在运行的 nginx。
if [ -x /etc/init.d/nginx ] && [ -f /etc/nginx/conf.d/mesh-sync.locations ] \
	&& [ -f /etc/nginx/uwsgi_params ] \
	&& grep -q 'conf\.d/\*\.locations' /etc/config/nginx 2>/dev/null; then
	/etc/init.d/nginx reload >/dev/null 2>&1
fi
rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -x /etc/init.d/mesh ] && /etc/init.d/mesh stop >/dev/null 2>&1
[ -x /etc/init.d/mesh ] && /etc/init.d/mesh disable >/dev/null 2>&1
# 漫游自检脚本的收尾：先清 cron 条目、再摘掉自启链接。
# 顺序很关键 —— 这两步都靠调用脚本自身（cron_disable / disable），必须在包管理器
# 删除 /etc/init.d/ 下的文件**之前**执行；反过来就全落空，留下每分钟报错的僵尸
# crontab 行（脚本已不存在，crond 照旧按分钟去拉起它）。
for s in 97-wifi-roaming 99-dawn-roaming; do
	[ -x "/etc/init.d/$$s" ] && "/etc/init.d/$$s" cron_disable >/dev/null 2>&1
	[ -x "/etc/init.d/$$s" ] && "/etc/init.d/$$s" disable >/dev/null 2>&1
done
exit 0
endef

$(eval $(call BuildPackage,luci-app-mesh))
