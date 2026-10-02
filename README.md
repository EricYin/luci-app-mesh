# luci-app-mesh — OpenWrt 802.11s + batman-adv Mesh 组网

OpenWrt LuCI 的无线 Mesh 组网插件（JavaScript 界面 + busybox ash 后端，无 Lua/luajit 依赖）。

两台 OpenWrt 路由器即可零布线组网：**主节点**接光猫出网、作为配置源；**子节点**插电自动跟随，全部物理端口并入内网。有网线时拉一根线即自动切换有线回程（二层直转、满线速），拔线无线回程无缝接管。全部操作在 LuCI 网页完成，无需命令行。

- 当前版本：`1.0.0-r21`（`PKG_RELEASE` 21）
- 适用：OpenWrt 21.02+（opkg）/ OpenWrt 25.12+（apk）；已实测斐讯 K2P（mt7621 / mt76）
- 许可：Apache-2.0

---

## 核心功能

| 功能 | 说明 |
|---|---|
| 一键组网 | 选角色（主/子节点）、填 Mesh ID 与回程密码，保存即自动完成 wireless / network / dhcp / firewall 全套配置，无线重启约 10~20 秒 |
| 802.11s 无线回程 | mesh point 模式，SAE 加密；默认 5GHz 信道 36（非 DFS 段），两端强制同信道，RSSI 接入门限可调（默认 -80 dBm） |
| batman-adv 路径选择 | 强制启用（缺内核模块或 batctl 时 apply 直接拒绝并提示安装命令）；按 TQ 传输质量自动择优，网关模式按角色自动（主节点 server / 子节点 client），无界面开关 |
| 有线回程（B 方案） | 所有物理端口与 bat0 同入 br-lan：插网线 → 网桥 MAC 学习直接转发（零 batman 开销、满线速）；拔线 → bat0 立即接管。跨 mesh 环路由 BLA 抑制，物理口之间的环由 STP 阻塞 |
| 子节点全端口内网化 | WAN/LAN 所有物理口并入 br-lan（swconfig VLAN 与 DSA 均自动处理），删除上行接口、关闭本机 DHCP；子节点自身与下挂终端地址一律由主节点分发（恒 `proto=dhcp`），br-lan MAC 钉成设备主 MAC 防租约漂移 |
| 配置自动同步 | 子节点守护进程每 10 秒经 `http://<主节点>/cgi-bin/mesh-sync` 拉取配置，镜像主节点的 SSID/密码/加密/802.11r；一致时不做任何变更（不重启无线） |
| AP 信道错开 | 主节点信道固定时，各子节点 AP 按注册序号在 2.4G {1,6,11} / 5G 36·149·44·157… 轮转错开，减少同频干扰（回程频段除外，回程必须同信道） |
| 回滚保护 | 应用后开启看护窗口（静态地址 120 秒 / DHCP 子节点 180 秒），到期管理地址不可达则自动还原组网前配置并整机重启；页面顶部出现「保留新配置 / 立即还原」确认条 |
| 备份与还原 | 首次启用自动把 wireless / network / dhcp / firewall 备份到 `/etc/mesh-backup/`（关闭再开启不覆盖）；「还原组网前配置」用备份整份覆盖四个配置并重启路由器，可完整恢复被删除的 WAN 口 |
| 能力自检 | 组网状态页顶部提示框集中显示缺失项：驱动 mesh point / 完整版 wpad / kmod-batman-adv / batctl / 漫游引导 dawn / umdns。组网必需项缺失 → 红框；组网可用但缺 dawn 或 umdns → 橙框提醒（不影响组网，只是客户端不会被引导切换） |
| 无线漫游自愈 | 随包安装两个幂等自检脚本（`97-wifi-roaming` / `99-dawn-roaming`），默认开机自启 + 每分钟 cron 巡检：前者补齐 AP 的 802.11k 邻居报告 / 802.11v BTM / 802.11r FT，后者校正 dawn 广播地址与 umdns 网络绑定。只在检测到配置漂移时才落盘并重载，配置正常时一轮开销约等于一次 md5sum；脚本带 mesh 守卫，未启用组网时完全静默 |
| LuCI 三页面 | 组网状态（能力检测、运行状态、网络拓扑、邻居节点）、组网设置、诊断与维护（还原组网前配置、端口并入内网） |

**强依赖**（`Makefile` `LUCI_DEPENDS`，编译安装自动拉齐）：

```
+uclient-fetch +rpcd +curl +jsonfilter +iwinfo +iw
+wpad-mesh-openssl        # 完整版 wpad（wpad-basic / wpad-mini 不带 mesh point）
+kmod-batman-adv +batctl  # batman-adv 路径选择
+luci-proto-batman-adv    # bat0 的 LuCI 协议：网页端才能新建/编辑 proto 'batadv' 的接口
+dawn +umdns              # 无线漫游引导：AP 间交换客户端信号/负载，用 802.11k/v 引导切换
```

---

## 目录结构

```
luci-app-mesh/
├── Makefile                                  # OpenWrt feed 打包（依赖 / conffiles / postinst）
├── install.sh                                # 免编译直装脚本（复制到设备上 sh install.sh）
├── docs/                                     # 赞助收款码
│   ├── donate-alipay.jpg
│   └── donate-wechat.png
├── htdocs/luci-static/resources/view/mesh/   # LuCI JS 界面
│   ├── overview.js                           #   组网状态
│   ├── settings.js                           #   组网设置
│   ├── tools.js                              #   诊断与维护
│   └── mesh.css
└── root/
    ├── etc/config/mesh                       # 默认 UCI 配置（conffile 保护，升级不丢活配置）
    ├── etc/init.d/mesh                       # procd 守护服务（S99，respawn）
    ├── etc/init.d/97-wifi-roaming            # 漫游自检：补齐 AP 的 802.11k/11v/11r（开机自启 + cron）
    ├── etc/init.d/99-dawn-roaming            # 漫游自检：校正 dawn 广播地址 / umdns 绑定
    ├── etc/hotplug.d/iface/30-mesh-bat-mtu   # 接口 up 时事件驱动补 bat0 hardif MTU
    ├── etc/nginx/conf.d/mesh-sync.locations  # Kwrt 等 nginx+uwsgi 固件专用（uhttpd 忽略）
    ├── usr/sbin/meshctl                      # 核心命令行，8 个子命令
    ├── usr/libexec/mesh/functions.sh         # 全部组网函数库（apply / revert / 同步 / 探测…）
    ├── usr/libexec/rpcd/mesh                 # ubus 插件：LuCI JS ↔ meshctl 的桥 + 命令白名单
    ├── usr/share/luci/menu.d/luci-app-mesh.json
    ├── usr/share/rpcd/acl.d/luci-app-mesh.json
    └── www/cgi-bin/mesh-sync                 # 主节点配置下发端点（CGI，返回 JSON）
```

`meshctl` 子命令：`apply`（应用组网，前后台各一段）、`status`（状态 JSON）、`diag`（诊断输出）、`sync`（手动同步一次）、`daemon`（守护循环）、`revert`（还原组网前配置）、`confirm_rollback`（保留新管理地址）、`port_bridging`（端口并入内网·手动）。

---

## 安装 / 编译

### 方式一：随固件编译（推荐，依赖自动拉齐）

把本目录放进 OpenWrt 源码树后正常编译：

```sh
# 二选一：直接放 package/ 下，或作为 luci feed 的包
cp -r luci-app-mesh <openwrt>/package/luci-app-mesh

make menuconfig    # LuCI → 3. Applications → luci-app-mesh 选 <M>
make package/luci-app-mesh/compile V=s
# 产物：bin/packages/<arch>/base/luci-app-mesh-1.0.0-r<N>.apk（25.12+）
#                    bin/packages/<arch>/base/luci-app-mesh_1.0.0-r<N>_all.ipk（23.05-）
```

`LUCI_DEPENDS` 的 9 项依赖由包管理器自动解析，开箱即用；`/etc/config/mesh` 已声明 conffile，升级不会覆盖你的活配置。（`kmod-mac80211` 不列入依赖：目标镜像的无线驱动如 mt76 已自动选入。）

### 方式二：免编译直装

**1）先补齐依赖**（按固件包管理器二选一）：

```sh
# OpenWrt 25.12+（apk）
apk update && apk add curl jsonfilter iwinfo iw uclient-fetch rpcd wpad-mesh-openssl

# OpenWrt 23.05 及更早（opkg）
opkg update && opkg install curl jsonfilter iwinfo iw uclient-fetch rpcd wpad-mesh-openssl

# batman-adv（两代固件通用；kmod 包必须与固件内核版本匹配）
apk add kmod-batman-adv batctl        # 或 opkg install kmod-batman-adv batctl

# bat0 的 LuCI 协议（纯前端，无内核耦合；缺它时网页端认不出 batadv 协议接口）
apk add luci-proto-batman-adv         # 或 opkg install luci-proto-batman-adv
```

**2）安装程序**，二选一：

```sh
# a. 包管理器装编译好的 ipk/apk
apk add --allow-untrusted luci-app-mesh-1.0.0-r21.apk
opkg install luci-app-mesh_1.0.0-r21_all.ipk

# b. 或把整个项目目录传到设备上，运行直装脚本（自动复制文件、重启 rpcd、启用服务）
sh install.sh
```

装完浏览器打开 `http://<设备IP>/cgi-bin/luci/` → **网络 → Mesh 组网**；菜单没出现就 Ctrl+F5 强刷（必要时重启 uhttpd）。

---

## 组网步骤

1. **主节点**（接光猫）：组网设置 → 角色选「主节点」→ 填 Mesh ID（默认 `OpenWrtMesh`）与回程密码（≥8 位，加密默认 SAE）→ 保存并应用。WAN 保持接光猫不动，DHCP 服务自动确保开启。
2. **子节点**：组网设置 → 角色选「子节点」→ 填**相同**的 Mesh ID 与密码 → 保存并应用。应用后子节点会删除 WAN 口、全端口并入内网、管理地址改为 DHCP 获取（出厂 `192.168.1.1` 会变化，请到主节点的 DHCP 租约列表找它的新地址）。
3. **等待回程建立**：两台都应用完约 1~2 分钟，组网状态页应看到邻居节点、mesh0 对端与 bat0 就绪；子节点 AP 名称/密码此后自动跟随主节点。
4. **（可选）有线回程**：任意一根网线连接两台设备的任意 LAN/WAN 口即可——端口已全部在 br-lan 内，插上就走二层直转，拔掉自动回落无线，无需任何配置。
5. **验证**：终端连接任一节点的 Wi-Fi 或网口，获取的地址应由主节点分发，可直接访问两台的 LuCI；组网状态页拓扑中两节点均在线。

> 常见坑：两端 Mesh ID 相同但**信道不同**时永远 0 对端——本包已强制同信道；K2P 之类单射频设备回程与 AP 共用射频，5G 回程时 2.4G AP 不受影响。

---

## 工作机制要点

- **组网拓扑（B 方案，唯一实现）**：所有物理端口与 `bat0` 同入 `br-lan`；`bat0` 的 hard interface 只有无线回程 `mesh0`（mesh0 本身不进网桥）。有线在线时流量走网桥 MAC 学习直达（满线速）；无线经 batman-adv 封包转发。跨 mesh 的环由 batman-adv **BLA**（桥环规避）抑制，物理口之间的环由 **STP**（定时器 4/1/6）阻塞，两者分工不冲突。
- **apply 的执行顺序**：校验参数与能力（驱动 / wpad / kmod-batman-adv / batctl，缺一拒绝）→ 首次备份 4 个配置 → 按角色改写 network/dhcp（子节点删 WAN、全端口进 br-lan、`proto=dhcp`）→ 建 mesh0 + bat0/batmesh + 桥接 → 开回滚保护窗口 → 提交并 `network restart` + `wifi reload`。
- **为什么「保存并应用」总是立刻返回成功**：子节点 apply 会把自己的 LAN 改成 DHCP 并重启网络，承载 RPC 应答的连接会被当场掐断——所以 rpcd 后台执行、立即返回 `code=0`。真实结果写入 `/tmp/mesh/last_apply`（tmpfs），设置页表单上方会显示「上次应用：成功/失败」，触发后 8 秒 / 22 秒各回读一次；**重启后记录消失，界面不再显示**。
- **配置同步协议**：子节点每 10 秒 `GET /cgi-bin/mesh-sync?mac=..&token=<回程密码>&link=wifi|wired` → 主节点校验角色 / enabled / token 后返回 JSON（含 AP 列表、信道、序号）；子节点按序号镜像配置，一致则跳过。链路类型由 station 表与入口端口判定，无线、有线断一个都能继续同步。
- **备份 / 还原 / 回滚语义**：`/etc/mesh-backup/` 只在首次启用时创建，停用再启用**不覆盖**；「还原」= 备份整份覆盖回 wireless/network/dhcp/firewall + `enabled=0` + 删备份 + 延迟 2 秒整机重启（先让成功应答返回页面）；自动回滚到期不可达时走同一条还原路径。
- **防静默失败**：能力缺失（wpad / kmod-batman-adv / batctl）在状态页红框明示 + apply 强制拦截；`capabilities` 中 `batctl` 独立于内核模块判定，避免「模块在、工具缺」时界面假绿。
- **漫游配置自愈（为什么用轮询而不是事件）**：本系列固件**不发 procd 的 `config.change` 事件**（命令行 `uci commit` 与 LuCI 的 `uci apply` 两条路径实测都不发），而 LuCI 无线页保存会**重写整段 wireless**，把 `rrm_neighbor_report` / `rrm_beacon_report` 这类它不认识的项直接冲掉。因此 `97-wifi-roaming` / `99-dawn-roaming` 采用每分钟 cron 巡检：配置未变时一轮只做一次 md5 比较即退出，检测到差异才 `uci commit` 并后台重载。两者都是**差异修复器**而非配置器——只补缺失项、不重写已正确的项，所以不会每次巡检都断一次无线。
- **mesh 守卫**：两个脚本都以 `/etc/config/mesh` 的 `enabled` 为总开关。安装时默认 `enable`（开机自启）+ `cron_enable`（每分钟巡检），但在未启用组网的设备上（`enabled != 1`）一律静默退出——**装包本身不会改动无线配置**；卸载时 `prerm` 自动清掉 cron 条目与自启链接。

---

## 变更记录

### r20（2026-09-24）
基于 r19 全量代码审查，修复三处逻辑缺陷（不改变既有正常组网行为，仅修正边界一致性）：
- **漫游自检 `fast_skip` 纳入脚本自身指纹**：`97-wifi-roaming` / `99-dawn-roaming` 的快速通道原本只比对配置文件的 md5，改了脚本强制规则后已部署设备永不重跑、旧规则滞留。现把脚本本体 `$0`（解析 rc.d 软链接后的真实路径）的 md5 并入指纹，脚本升级 / 调参后必然重新执行。
- **AP 镜像尊重主节点 `disabled` 状态**：`mesh-sync` 下发 AP 时新增 `disabled` 字段，子节点按主节点意图镜像（主节点有意关闭的 AP，子节点不再强制开启）。`mesh_wifi_ensure_aps_up` 已对 `disabled=1` 的 AP 跳过，不会把镜像结果又顶回去。
- **配置镜像循环不再因空 SSID 提前退出**：`meshctl` 载入主节点 AP 列表时，改以「band 下标是否真实存在」为哨兵，空 SSID（合法隐藏网络）不再导致后续 AP 漏镜像。

### r21（2026-09-28）
修复组网设置「回程频段 / 回程信道」不联动、且频段不按实际硬件列出的问题：
- **回程频段按硬件列出**：`meshctl status` 新增 `channels` 字段（各射频用 `iw phy info` 取真实信道号，含 DFS）；前端据此只显示本机实际拥有的频段（没有的频段不出现），默认频段也按硬件择优。
- **回程信道随频段联动**：原来信道下拉把 5G/2.4G 信道静态混在一个列表里、与频段选择毫无关联。现拆成 `channel_5g/2g/6g/auto` 四个选项，各自 `depends('band', …)` —— 选 5G 只列 5G 信道、选 2.4G 只列 2.4G 信道，LuCI 在切换频段时自动显隐并重渲染；四个选项映射到同一 UCI 项 `channel`，隐藏时不删值。

---

## 赞助

如果这个项目对你有帮助，欢迎请作者喝一杯 🙂

| 支付宝 | 微信支付 |
|:---:|:---:|
| <img src="docs/donate-alipay.jpg" width="220" alt="支付宝收款码"> | <img src="docs/donate-wechat.png" width="220" alt="微信收款码"> |
