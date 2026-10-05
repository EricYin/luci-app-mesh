# luci-app-mesh — OpenWrt 802.11s + batman-adv Mesh 组网

OpenWrt LuCI 的无线 Mesh 组网插件（JavaScript 界面 + busybox ash 后端，无 Lua/luajit 依赖）。

两台 OpenWrt 路由器即可零布线组网：**主节点**作为上网网关出网、作为配置源；**子节点**插电自动跟随，全部物理端口并入内网。有网线时拉一根线即自动切换有线回程（二层直转、满线速），拔线无线回程无缝接管。全部操作在 LuCI 网页完成，无需命令行。

- 当前版本：`1.0.0-r35`（`PKG_RELEASE` 33）
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
| 一键加入（配对） | 新节点免手工填参数：主节点点「开放加入」临时起一个配对信号（固件固定 SSID/密码），子节点点「一键加入」连上来领取 Mesh ID 与回程密码并自动应用。窗口默认 10 分钟自动关闭，可改或设为常开；窗口关着时配对信号根本不存在，固定密码不构成风险 |
| 配置自动同步 | 子节点守护进程每 10 秒经 `http://<主节点>/cgi-bin/mesh-sync` 拉取配置，镜像主节点的 SSID/密码/加密/802.11r；一致时不做任何变更（不重启无线） |
| AP 信道错开 | 主节点信道固定时，各子节点 AP 按注册序号在 2.4G {1,6,11} / 5G 36·149·44·157… 轮转错开，减少同频干扰（回程频段除外，回程必须同信道） |
| 回滚保护 | 应用后开启看护窗口（静态地址 120 秒 / DHCP 子节点 180 秒），到期管理地址不可达则自动还原组网前配置并整机重启；页面顶部出现「保留新配置 / 立即还原」确认条 |
| 备份与还原 | 首次启用自动把 wireless / network / dhcp / firewall 备份到 `/etc/mesh-backup/`（关闭再开启不覆盖）；「还原组网前配置」用备份整份覆盖四个配置并重启路由器，可完整恢复被删除的 WAN 口 |
| 能力自检 | 组网状态页顶部提示框集中显示缺失项：驱动 mesh point / 完整版 wpad / kmod-batman-adv / batctl / 漫游引导 dawn / umdns。组网必需项缺失 → 红框；组网可用但缺 dawn 或 umdns → 橙框提醒（不影响组网，只是客户端不会被引导切换） |
| 无线漫游自愈 | 随包安装两个幂等自检脚本（`97-wifi-roaming` / `99-dawn-roaming`），默认开机自启 + 每分钟 cron 巡检：前者补齐 AP 的 802.11k 邻居报告 / 802.11v BTM / 802.11r FT，后者校正 dawn 广播地址与 umdns 网络绑定。只在检测到配置漂移时才落盘并重载，配置正常时一轮开销约等于一次 md5sum；脚本带 mesh 守卫，未启用组网时完全静默 |
| LuCI 三页面 | 组网状态（能力检测、运行状态、网络拓扑、节点列表）、组网设置、诊断与维护（还原组网前配置、端口并入内网） |

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
apk add --allow-untrusted luci-app-mesh-1.0.0-r35.apk
opkg install luci-app-mesh_1.0.0-r35_all.ipk

# b. 或把整个项目目录传到设备上，运行直装脚本（自动复制文件、重启 rpcd、启用服务）
sh install.sh
```

装完浏览器打开 `http://<设备IP>/cgi-bin/luci/` → **网络 → Mesh 组网**；菜单没出现就 Ctrl+F5 强刷（必要时重启 uhttpd）。

---

## 组网步骤

1. **主节点**（上网网关）：组网设置 → 角色选「主节点」→ 保存并应用。**Mesh ID 与回程密码可留空**——留空时主节点首次应用会自动生成：Mesh ID 按本机 MAC 派生为 `XxMesh-XXXXXX`（避免与邻居的同款固件重名），回程密码为 16 位随机串；生成后长期固定。也可以自己填（填了就以你填的为准，不会被改掉）。WAN 保持上行不动，DHCP 服务自动确保开启。
2. **子节点（两种方式二选一）**：
   - **一键加入（推荐，不用知道任何密码）**：组网设置 → 角色选「子节点」→ 启用 → 保存并应用；再到组网状态页点「一键加入」，然后去主节点点「开放加入」。子节点会自动连上配对信号、领走 Mesh ID 与回程密码并自动应用。先后顺序无所谓——子节点会一直等（默认 5 分钟）到主节点开窗为止。
   - **手工填**：组网设置 → 角色选「子节点」→ 填**相同**的 Mesh ID 与密码 → 保存并应用。
   两种方式应用后子节点都会删除 WAN 口、全端口并入内网、管理地址改为 DHCP 获取（出厂 `192.168.1.1` 会变化，请到主节点的 DHCP 租约列表找它的新地址）。
3. **等待回程建立**：两台都应用完约 1~2 分钟，组网状态页应看到节点列表、mesh0 对端与 bat0 就绪；子节点 AP 名称/密码此后自动跟随主节点。
4. **（可选）有线回程**：任意一根网线连接两台设备的任意 LAN/WAN 口即可——端口已全部在 br-lan 内，插上就走二层直转，拔掉自动回落无线，无需任何配置。
5. **验证**：终端连接任一节点的 Wi-Fi 或网口，获取的地址应由主节点分发，可直接访问两台的 LuCI；组网状态页拓扑中两节点均在线。

> 常见坑：两端 Mesh ID 相同但**信道不同**时永远 0 对端——本包已强制同信道；K2P 之类单射频设备回程与 AP 共用射频，5G 回程时 2.4G AP 不受影响。

---

## 工作机制要点

- **组网拓扑（B 方案，唯一实现）**：所有物理端口与 `bat0` 同入 `br-lan`；`bat0` 的 hard interface 只有无线回程 `mesh0`（mesh0 本身不进网桥）。有线在线时流量走网桥 MAC 学习直达（满线速）；无线经 batman-adv 封包转发。跨 mesh 的环由 batman-adv **BLA**（桥环规避）抑制，物理口之间的环由 **STP**（定时器 4/1/6）阻塞，两者分工不冲突。
- **apply 的执行顺序**：校验参数与能力（驱动 / wpad / kmod-batman-adv / batctl，缺一拒绝）→ 首次备份 4 个配置 → 按角色改写 network/dhcp（子节点删 WAN、全端口进 br-lan、`proto=dhcp`）→ 建 mesh0 + bat0/batmesh + 桥接 → 开回滚保护窗口 → 提交并 `network restart` + `wifi reload`。
- **为什么「保存并应用」总是立刻返回成功**：子节点 apply 会把自己的 LAN 改成 DHCP 并重启网络，承载 RPC 应答的连接会被当场掐断——所以 rpcd 后台执行、立即返回 `code=0`。真实结果写入 `/tmp/mesh/last_apply`（tmpfs），设置页表单上方会显示「上次应用：成功/失败」，触发后 8 秒 / 22 秒各回读一次；**重启后记录消失，界面不再显示**。
- **一键加入（配对）为什么用「两把钥匙」**：回程密码既是 802.11s 的 SAE 密钥、也是子节点拉配置的令牌，出厂/恢复出厂的新节点手里没有它，连问都问不到——所以必须另开一条**免鉴权**通道。配对密码是固件里写死的固定值（`XxMesh-Pair` / `xxmesh-pair`），它只在一扇"平时根本不存在"的门上有效：窗口关闭时配对 AP 压根没起来，知道密码也连不上。风险窗口就是开窗的那几分钟，兜底是"得本人在现场开窗"。主节点开窗后，这个配对信号会经现有的 AP 镜像机制**自动同步到所有子节点**，新节点可以就近连信号最好的那个，凭证请求经 bat0 二层域照样回到主节点。
- **配对为什么不能用「第二个 mesh 接口」**：`wpa_supplicant` 一个进程只允许加入一个 mesh group，真机实测第二个 mesh 起来后正式回程立刻被踢（`Avoiding join because we already joined a mesh group`），所以配对通道只能走 AP/STA。配对 STA 还必须是独立 interface 且 `defaultroute=0`：桥进 `br-lan` 会与主节点的配对 AP 成环，走 dhcp 又会抢走默认路由。
- **配置同步协议**：子节点每 10 秒 `GET /cgi-bin/mesh-sync?mac=..&token=<回程密码>&link=wifi|wired` → 主节点校验角色 / enabled / token 后返回 JSON（含 AP 列表、信道、序号）；子节点按序号镜像配置，一致则跳过。链路类型由 station 表与入口端口判定，无线、有线断一个都能继续同步。
- **备份 / 还原 / 回滚语义**：`/etc/mesh-backup/` 只在首次启用时创建，停用再启用**不覆盖**；「还原」= 备份整份覆盖回 wireless/network/dhcp/firewall + `enabled=0` + 删备份 + 延迟 2 秒整机重启（先让成功应答返回页面）；自动回滚到期不可达时走同一条还原路径。
- **防静默失败**：能力缺失（wpad / kmod-batman-adv / batctl）在状态页红框明示 + apply 强制拦截；`capabilities` 中 `batctl` 独立于内核模块判定，避免「模块在、工具缺」时界面假绿。
- **漫游配置自愈（为什么用轮询而不是事件）**：本系列固件**不发 procd 的 `config.change` 事件**（命令行 `uci commit` 与 LuCI 的 `uci apply` 两条路径实测都不发），而 LuCI 无线页保存会**重写整段 wireless**，把 `rrm_neighbor_report` / `rrm_beacon_report` 这类它不认识的项直接冲掉。因此 `97-wifi-roaming` / `99-dawn-roaming` 采用每分钟 cron 巡检：配置未变时一轮只做一次 md5 比较即退出，检测到差异才 `uci commit` 并后台重载。两者都是**差异修复器**而非配置器——只补缺失项、不重写已正确的项，所以不会每次巡检都断一次无线。
- **mesh 守卫**：两个脚本都以 `/etc/config/mesh` 的 `enabled` 为总开关。安装时默认 `enable`（开机自启）+ `cron_enable`（每分钟巡检），但在未启用组网的设备上（`enabled != 1`）一律静默退出——**装包本身不会改动无线配置**；卸载时 `prerm` 自动清掉 cron 条目与自启链接。

## 按键一键组网（WPS 键）

不用进网页：按机身 WPS 键即可完成组网。**按法即意图** —— 谁开窗谁是主节点、谁加入谁是子节点，
按键顺带把角色写对，所以出厂机开箱直接按就行，不需要先去网页选角色。

| 按法 | 出厂 / 未组网 | 子节点已在网 | 主节点已在网 |
|---|---|---|---|
| **≤4s** | 设为子节点 + 一键加入 ← 开箱自举 | 拒绝（红灯急闪）| 拒绝（红灯急闪） |
| **5~9s** | 设为主节点 + 开窗 10 分钟 ← 开箱自举 | 拒绝 | 窗口已开则关窗，否则开窗 |
| 10~13s | 空档（防手抖） | 空档 | 空档 |
| **14~20s** | 无备份则拒绝 | 退出组网并重启 | 退出组网并重启 |
| >20s | 忽略 | 忽略 | 忽略 |

- **退出档带 10 秒反悔窗口**：松手后红灯急闪，期间再按一次键即取消（`mesh.main.btn_exit_grace`）。
- **实现方式**：只放一个 `/etc/rc.wps/10-mesh` —— `/etc/rc.button/wps` 是个分发器
  （`for script in /etc/rc.wps/*; do "$script" && break; done`），文件名排最前就能先执行，
  返回 0 即 break。**不备份、不覆盖任何系统文件**，卸载删掉这一个文件即恢复原样。
- **LED 反馈**：`phone → wlan → power` 自动回退（被拒绝、退出前的反悔期用红灯），
  动作结束后自动还原这盏灯原来的 trigger。
- **按住期间没有实时提示**：分发器只在松手（released）时回调，拿不到 `pressed`，
  所以退出档得自己数秒 —— 这是"不接管 `rc.button/wps`"换来的零系统文件改动。
- **副作用**：装上后系统自带 WPS 失效（短按也不再是手机免密连入）。
  设 `mesh.main.button=0` 即完全让位，按键行为恢复原样。
- **⚠️ 已知风险**：子节点走"加入"档会执行 apply（重建 mesh 回程并重启网络）。
  **纯无线回程**的节点一旦回程没能重建，就没有有线兜底、会失联 —— 实测遇到过一次。
  排障：插一根网线到主节点（有线回程立刻恢复通路），或长按 14~20 秒退出组网还原；
  就算什么都不做，回滚窗口（子节点 240 秒）发现新地址不可达也会自动还原组网前配置。
- **⚠️ 加入档只服务"手里没凭证"的节点**：已在网的子节点按 ≤4s 会被拒绝
  （`enabled=1` 且 `mesh_id` 非空即视为在网）。因为加入档要先切射频去连配对信号、
  再 apply 重建网络，正在跑的无线回程会被打断；有线节点能靠回滚窗口救回来，
  纯无线节点就是直接失联。要重新入网，先长按 14~20 秒退出组网，再按一次。

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

### r22（2026-10-02）
修复「本机明明是主节点、`/cgi-bin/mesh-sync` 却恒返回 `not_master`、组网始终起不来」这个极难自查的故障（真机复现并验证：PonWrt / aarch64 两台）：
- **根因不在 mesh 协议，而在配置项没落盘**：LuCI 的 `m.save()` 只提交「值发生变化」的项，而 `role` / `encryption` / `country` / `band` 在设置页都是**带默认值的下拉框**——用户没动过时界面照常显示 `master` / `sae` / `CN`，UCI 里却没有这些键。于是 `meshctl apply` 在 `[1/7]` 就报「请选择本节点角色」退出，`mesh0` / `bat0` 从未建立，子节点只能拿到 `not_master`。用户手改过的 `enabled` / `mesh_id` / `channel` / `mesh_key` 反而都在，所以单看配置文件很难看出缺了什么。
- **★ 真凶：LuCI 不是「没写」，是主动删**。上一版判定只说对了一半。设备上的 `form.js` 里 `AbstractValue.parse()` 是这样的：
  ```js
  if (fval == null || fval == '' || (fval == this.default && (this.optional || this.rmempty))) {
      if (this.rmempty || this.optional) return this.remove(section_id);   // → uci.unset()
  } else if (this.forcewrite || !isEqual(cval, fval)) {
      return this.write(section_id, fval);
  }
  ```
  `rmempty` 在 LuCI 里默认就是真，所以**下拉框停在默认值上 = 保存时把这个键从 UCI 里删掉**。用户「什么都没改」反而被抹掉出厂默认值；手改过的项（`fval != default`）走 `write()` 才留下来——这正是现场配置文件里 `enabled` / `mesh_id` / `channel` / `mesh_key` 在、而 `role` / `encryption` / `country` / `band` / `master_addr` 全没了的成因。
- **设置页根治（两层，缺一不可）**：
  1. `role` / `encryption` / `band` / `country` 四个 ListValue 各加 `o.rmempty = false`。为假后不再走 `remove` 分支，而 `cfgvalue()` 不回退 `default`（只有 `textvalue` 回退），于是 `cval=null != fval` → 走 `write()`，缺失即写入、已存在且未改动则不动。
  2. `ensureKeyOptions()` 补写空值项，且**调用时机是成败关键**：必须放进 `m.save(ensureKeyOptions)` 回调里（在 `parse()` 之后、真正发起 uci 保存之前）。放在 `m.save()` **之前**（第一版补丁就是这么写的）会被随后的 `parse()` 里的 `remove()` 直接取消，实测无效。
- **状态页不再撒谎**：`meshctl status` 原来把空的 `role` 兜底成 `master`——这正是「我明明是主节点」的来源。现在如实上报（`role` 为空 + `role_set=0`），同步状态也不再显示「配置源(下发中)」；`role_set=0` 时状态页顶部红框提示、「本机角色」卡显示未选择。
- **报错可读**：`mesh-sync` 的 `not_master` 拆成 `disabled` / `role_unset` / `not_master`（后两者附实际值），各带一句 `hint`；`meshctl apply` 报未设置角色时直接给出可执行的修复命令。

### r23（2026-10-03）
修复「预装固件场景下 802.11k/11v/11r 与 dawn 广播地址长期缺失」：
- **现象**：主节点无线配置半残（有 `ieee80211k` / `bss_transition`，缺 `ieee80211v` / `rrm_neighbor_report` / `rrm_beacon_report`），子节点全空。看起来像「k/v 没同步」，实际上 **k/v 本来就不走同步通道**——它们是每台 AP 的本地能力，设计上由随包的 `97-wifi-roaming` / `99-dawn-roaming` 在各节点自己补齐。
- **根因（三环，缺一不可）**：
  1. `enable` + `cron_enable` 写在 Makefile 的 `postinst` 里，那是 **opkg/apk 安装**钩子。把包编译进 image（随固件预装）时没有安装动作，postinst 一次都没跑 → cron 巡检条目从未建立。
  2. 开机那唯一一次机会也落空：`97-wifi-roaming` 的 `start()` 开头有 mesh 守卫（`mesh.main.enabled` 必须为 1），新机首次开机用户还没启用组网，值为 0 直接 `return 0`。
  3. 之后就再无触发点。而这两个脚本存在的意义正是**配置漂移自愈**——本系列固件不发 procd 的 `config.change` 事件，`procd_add_config_trigger` 无效，只能靠轮询；LuCI 无线页一保存会重写整段 wireless，把这些项冲掉后再没人补得回来。
- **修法**：新增 `root/etc/uci-defaults/40-luci-app-mesh-roaming`，由 Makefile 的 install 段装进 `/etc/uci-defaults/`。uci-defaults 由 `/etc/init.d/boot` 在**首次开机**执行（成功即自删），是唯一能在「预装 + 首次启动」这个时间点做初始化的官方机制，用来把 postinst 欠下的事补回来。脚本内部同样只调两个 init 脚本自带的 `enable` / `cron_enable`，保持单一真相源；两者都幂等，与 postinst 重复执行也无副作用。
- **不改同步协议**：11k/11v 是本机能力而非全网契约，主节点自己缺项时会反向传染子节点；且 `ap[]` 是 `IFS='|'` 的位置解析，加字段等于改协议、主子版本错配就错位。
- **已知边界**：uci-defaults 只在首次开机跑一次、跑完自删。已刷过的机器将来用 sysupgrade **保留配置**升级时它不会再执行，需要手动补一次（`/etc/init.d/97-wifi-roaming cron_enable` 与 99 同名命令），或后续再加开机 `boot()` 钩子做二次加固。

---

---

### r24（2026-10-05）
回程凭证自动生成 + 修好设置页密码工具按钮：
- **Mesh ID 按本机 MAC 派生**：主节点首次应用且 `mesh_id` 为空时，派生为 `XxMesh-<MAC 后 6 位>` 并写回 UCI。全网同固件不再都叫同一个名字——同信道上邻居的同款设备会反复尝试 SAE 握手（空口干扰 + 刷日志）。取 MAC 时特意避开 `bat0`（它是 batman-adv 的软接口，MAC 由 batman 自己生成），只从 `eth*`/`br-lan` 取。
- **回程密码自动生成**：同样只在为空时生成 16 位 `[A-Za-z0-9]` 随机串（不含 `+/=` 等 URL 保留字符——它要拼进同步请求的查询串）。判定只看"是否为空"，用户手工填的弱密码不会被悄悄改掉。
- **出厂配置必须留空**：`/etc/config/mesh` 里 `mesh_id` / `mesh_key` 改成空串。原来写死 `OpenWrtMesh`，新刷机永远走不到派生逻辑。
- **修好密码工具按钮点了没反应**：LuCI 的密码框是**两层结构**——`getElementById('cbid.mesh.main.mesh_key')` 拿到的是外层 `div`，真正的 `input` 的 id 是 `widget.cbid.mesh.main.mesh_key`；且 `<button>` 在 form 里默认 `type=submit`，不写就会触发保存。现在按 `widget.` → 容器内 `input` → `input.cbi-input-password` 三级查找，并全部显式 `type=button`。

### r25（2026-10-05）
后端打通「一键加入」：新增 `action=join` 端点与 `meshctl pair-open / pair-close / pair-status / pair-join`（真机端到端验收通过）。
- **免鉴权端点必须放在 token 校验之前**：`mesh-sync` 的 token 就是回程密码，出厂节点连那道门都敲不开——"先有凭证还是先有连接"这个死循环只能靠一条免鉴权通道解开。安全性只依赖「只有已启用组网的主节点响应」+「只在窗口期响应」。
- **窗口到期改由守护进程收摊**：早期版本用一次性 `sleep` 后台进程看门狗，连续开窗时残留的旧进程会把新窗口误关。现在窗口是一个 expire 时间戳，守护进程每 10 秒核对（实测 240 秒窗口准时自动关闭）。
- **配对 STA 必须先对齐信道**：同一 phy 上所有接口共享**一个**信道，STA 没法独自跳频——真机实测子节点射频在 ch11、配对 AP 在 ch1 时永远关联不上。所以起 STA 前先用 `mesh_pair_scan_channel` 扫出配对信号所在信道并临时切过去，用完还原。
- **踩坑记录**：`jsonfilter` 表达式里带连字符的键必须写成 `@['ipv4-address'][0]['address']`，写成 `@.ipv4-address[0].address` 会报 `Invalid escape sequence` 且**静默返回空**（表现为"接口明明 up 了，脚本却以为没拿到地址"）。

### r26（2026-10-05）
把一键加入做成网页按钮（第三步）：rpcd 放行 `pair_*` 并后台化，组网状态页加配对卡片、组网设置页加配对设置区。
- **三个配对动作必须后台执行并立即返回**：`pair-open` / `pair-close` 会触发 `wifi reload`（十几秒），`pair-join` 最坏要等满 5 分钟并紧接着跑一次 `apply`（子节点会改 IP + 重启网络）。同步等只会让 rpcd 连接超时、前端看到"网络错误"。真实结果写进 `/tmp/mesh/pair-last`（tmpfs，重启即消失），进度行写 `/tmp/mesh/pair.log`。
- **进度可见**：`meshctl status` 新增 `pair` 块（窗口状态 / 剩余秒数 / 已加入台数 / 后台任务 busy / 上次结果 / 最新进度行），状态页 10 秒一轮的轮询顺带刷新，不用额外加定时器。
- **网页上开窗可改时长**（默认 10 分钟，可选 2/5/10/30 分钟或常开），开窗期间显示倒计时、配对 SSID/密码、已加入台数，可随时「立即关闭」。
- 仓库归属整理：`origin` 指向 `https://github.com/xxosdev/luci-app-mesh.git`，维护者改为 `Xx`，移除原作者的赞助收款码。

### r27（2026-10-05）
文案与默认值统一，不含功能改动。
- 角色标签「主节点(接光猫 · 配置源)」→「**主节点(上网网关 · 配置源)**」（设置页下拉、状态页角色卡片，以及两处说明文字）。主节点的上行不一定是光猫（光猫桥接 / 上级路由 / 旁路等情况同样成立），写"上网网关"才准确。
- 「已连接邻居」→「**已连接节点**」；状态页最下面的大框标题「邻居节点」→「**节点列表**」，框内表格第一列的列头「邻居节点」→「**节点**」。空表提示同步改为「暂无已连接的节点」。
- 配对信号默认值改为 **`XxMesh-Pair` / `xxmesh-pair`**（原 `PonWrt-Pair` / `ponwrt-pair`），与 Mesh ID 的 `XxMesh-` 前缀一致：`functions.sh` 的两个 DEFAULT 常量、`/etc/config/mesh` 的出厂值、设置页两个 placeholder、状态页配对卡片的兜底显示全部同步。
  ⚠ 已经配过的机器不受影响（UCI 里已有值就用已有值），只有恢复出厂或 `uci set mesh.main.pair_ssid=...` 才会拿到新默认；若全网已有节点用的是旧值，请手动统一。

### r28（2026-10-05）
状态页直接选角色，不再把人支到设置页。
- **新增 `meshctl set-role master|client`**：写 `mesh.main.role` + `enabled=1` 并 commit，
  **只落配置、不应用**。理由是子节点此时手里没有凭证，立刻 apply 必然报
  「子节点没有 Mesh ID」——那是预期内的失败，不该在用户刚点完按钮就弹出来。
  主节点额外把空的 Mesh ID / 回程密码先派生出来（复用与 apply 相同的解析器），
  这样点「开放加入」时才有东西发给新节点。与 apply 共用同一把配置锁。
- **rpcd 放行 `set_role`**（同步执行，毫秒级；`arg` 必须是 `master` 或 `client`）。
- 前端：状态页「一键加入」区块在未选角色 / 未启用时，直接给「设为主节点并启用」
  「设为子节点并启用」两个按钮（子节点那段强调**先别应用、先领凭证**）；
  顶部角色红框也改成指向这两个按钮。
- 为支持整页即时重画，`render()` 的内容抽成 `buildBody(d)`，`repaintAll()` 直接
  替换根节点 —— 不用 `location.reload()`（那会把整个 LuCI 外壳重新加载一遍）。

### r29（2026-10-05）
修两个长期误报的显示问题。

**①「端口内网化」恒为 false（主子节点都报“部分端口未并入”）**
- 根因：这几台机器**根本没有 `wan*` 端口**（上行是 `pon0` 光口），而枚举函数写的是
  `ls -d /sys/class/net/lan* /sys/class/net/wan*` —— `wan*` 不匹配时**整条命令返回非 0**，
  于是掉进 `eth*` 兜底分支，把 DSA 的 conduit **`eth0`** 当成物理口。期望成员变成
  `eth0 bat0`，而 eth0 不可能出现在 br-lan 的成员里，判定自然永远失败。
- 改法：`lan*` 与 `wan*` **分开判断，任一存在即按 DSA 处理**；`eth*` 只在两者都不存在时兜底。
- 语义修正（主节点）：主节点本来就要保留上行口，不该拿“全端口内网化”这把尺子量它。
  现在主节点**只校验 bat0 是否真的在 br-lan 里**，文案改为
  「主节点：bat0 已并入 br-lan（上行口按要求保留，全端口内网化不适用）」。
  子节点维持全量校验（全部物理口 + bat0）。

**② 节点列表里的“幽灵行”（掉线的子节点一直挂在那里）**
- 根因：注册表只在**有子节点上报**时才顺带清理一次，且阈值硬编码 **24 小时**。
  于是“最后一台子节点掉线后再无上报”时，那条记录会一直以 offline 常驻一整天。
- 改法：
  - 新增 `mesh_registry_ttl()`（`mesh.main.peer_ttl`，默认 **3600** 秒，下限 60），
    替换原来的硬编码 86400；下限取 60 是为了不把“正在重启/升级”的节点删掉重排号
    （节点序号按首次注册时间排，决定信道错开）。
  - 新增 `mesh_registry_prune()`，并在 **`meshctl status` 里主动调一次** ——
    status 是界面每 10 秒都会走的路径，这样即使全网再无上报也能自愈。
  - peers JSON 增加 `lastseen`（epoch），离线行在界面上显示「最后上报 X 前」，
    据此分辨“刚重启”和“早就不在了”。
  - 设置页「链路控制」新增「离线节点保留时长(秒)」。

**顺带**：`mesh_brlan_members_report` 现在会打印判定口径、上行口排除清单与缺失项，
排障时能一眼看出到底按什么规则算的。

### r30（2026-10-05）
按键一键组网：WPS 键按时长分档，出厂机开箱直接按即可入网。

- **新增 `/etc/rc.wps/10-mesh`**：挂在系统 WPS 分发器下，**不动任何系统文件**。
  档位 ≤4s 加入 / 5~9s 开窗（已开则关窗）/ 10~13s 空档 / 14~20s 退出 / >20s 忽略，
  全部数值可在网页「按键组网（WPS 键）」里改（`mesh.main.btn_*`）。
- **`meshctl button press <SEEN>|join|open|exit|status`**：分档后再按角色与"是否已在网"判断。
  出厂机未启用时按键照样生效（这是"开箱自举"的前提）；已在网主节点按加入档、
  已在网子节点按开窗档都会被拒绝并闪红灯（前者会让全网失去配置源）。
  主节点从未应用过（没有 mesh 接口）时会先 apply 一次再开窗，否则新节点领了凭证也连不上。
- **退出档带 10 秒反悔窗口**：松手后红灯急闪，期间再按一次键即取消（`/tmp/mesh/button-pending-exit`）。
- **LED**：`mesh_led_pick()` 三级回退 + 危险操作用红灯；闪烁靠 token 判定自己是否过时，
  **闪完自动还原原 trigger**（否则 `blue:wlan` 会从 `phy0radio` 变成 `none`，等于弄坏射频指示灯）。
- 状态页显示「本次由按键触发」（op/按住秒数/时间/结果），设置页新增按键区。
- 守护进程自动关窗时补 `mesh_led_clear`：自动关窗不走按键路径，否则灯会一直亮着。

### r31（2026-10-05）
修两处"退出组网退不干净 / 加入档误伤在网节点"：

- **还原组网前配置时清掉残留凭证**：`mesh_do_revert` 原来只还原
  `wireless / network / dhcp / firewall`，**`/etc/config/mesh` 原封不动**，
  于是网络虽然退干净了，界面上还挂着 Mesh ID、回程密码、主节点地址和"子节点"
  身份 —— 真机 .219 被回滚窗口自动还原后就是这个样子，看着像"没退干净"。
  现在备份（并还原）列表加上 `mesh`，还原后强制清空 `mesh_id` / `mesh_key` /
  `master_addr` 并置 `enabled=0`，让本机回到"从未入网"状态，同时保住用户自己
  调过的按键档位、TTL、配对参数。
- **已在网的子节点按「加入」档一律拒绝**：与"已在网主节点拒绝降级"对称。
  加入档会先切射频连配对信号、再 apply 重建网络，正在跑的无线回程会被打断；
  这不是理论风险 —— 那台纯无线回程的 .219 就是这么被打离线、最后由回滚窗口
  自动还原的。提示语里直接给出正确路径：先长按 14~20 秒退出组网，再按一次。

### r32（2026-10-05）
修"配对信号连上了、地址也拿到了，却永远领不到凭证"（真机 .219，耗满 300 秒超时）：

- **同网段路由陷阱**：待入网的节点自己是个独立路由器（内网 `192.168.1.219/24`），
  配对 STA 又从主节点拿到 `192.168.1.132/24` —— **同一个子网出现在两个接口上**，
  内核有两条同前缀直连路由，去 `192.168.1.1` 的报文挑了先起来的 br-lan，
  而 br-lan 那一侧根本没有通往主节点的链路。`curl --interface` 只 bind 源地址、
  **不改出口设备**，所以主节点一个包都收不到，页面表现就是一直在"等待主节点开放加入"。
- **修法（r32，不够）**：给每个候选主节点地址钉一条走 STA 的 `/32` 主机路由
  （`ip route replace <master> dev <sta> src <ip>`）。真机复测**仍然失败**——
  因为设备名 `pairsta0` 是 wifi-iface 里的 `ifname`，只是**请求**，实际叫什么由
  wifi-scripts 决定；名字对不上时 `ip route replace` 报 "Cannot find device"
  又被 `2>/dev/null` 吞掉，等于什么都没做。
- **r33（真正的修法）**：
  1. 出口设备运行时解析：netifd `device` → `l3_device` → `ip -o link` 扫 `*staN`
     → 旧常量兜底，并打印"配对网卡"一行；
  2. `curl --interface <设备名>`（SO_BINDTODEVICE）—— 把路由查找也限制在这张网卡上，
     不再依赖主机路由；
  3. 配对期间临时关 `rp_filter`（回包从 STA 进来、反向路径算到 br-lan 会被丢），
     cleanup 按原值还原；
  4. 绑设备名拿不到响应时退回绑源地址（老写法），双保险。

### r34（2026-10-05）
**待入网节点的内网地址不能和主节点同号**（出厂路由器默认 `192.168.1.1`，一撞一个准）：

- 该地址一旦是本机自己拥有的，发往它的报文被内核**本地投递**（local 路由表优先于
  main 表，连 SO_BINDTODEVICE 都压不过），curl 实际打到了自己的 uhttpd 拿回
  `not_master`，然后干等 300 秒超时 —— 主节点那边一点痕迹都没有，极难排查。
- 这事没法从网络层救（你没法"访问"一个你自己拥有的地址），只能改本机内网。
  所以 `[3/4]` 先把候选地址里与本机地址相同的剔掉，**全被剔光就立刻报错**并给出
  指引（改成同网段其它地址，如 `192.168.1.219`），不再让用户白等 5 分钟。
  ⚠ 同网段本身没问题（r33 已解决），撞的是"同号"不是"同段"。

### r35（2026-10-05）
让**恢复出厂的设备（内网 192.168.1.1）也能真正开箱一键组网** —— 不用先手动改 IP：

- 撞号在网络层无解，但可以**换个地址敲门**：主节点开窗期间在 LAN 桥上临时挂一个
  `/32` 别名 `192.0.2.1`（RFC 5737 TEST-NET-1，真实网络里不存在，不会被内核特殊处理），
  关窗立刻摘掉（`mesh_pair_alias_up/down`）。
- 待入网节点检测到撞号后，把候选地址换成这个备用地址：它不是本机地址 → 不会被本地
  投递；再叠加 r33 的绑设备发送 + 主机路由，报文就能从配对网卡正常出去。
- 只在检测到撞号时才走这条路，正常场景零额外开销；主节点版本较旧（没挂备用地址）
  时仍会超时，但超时提示会说明原因。

