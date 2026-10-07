# luci-app-mesh — OpenWrt 802.11s + batman-adv Mesh 组网

OpenWrt LuCI 的无线 Mesh 组网插件（JavaScript 界面 + busybox ash 后端，无 Lua/luajit 依赖）。

两台 OpenWrt 路由器即可零布线组网：**主节点**作为上网网关出网、作为配置源；**子节点**插电自动跟随，全部物理端口并入内网。有网线时拉一根线即自动切换有线回程（二层直转、满线速），拔线无线回程无缝接管。全部操作在 LuCI 网页完成，无需命令行。

- 当前版本：`1.0.0-r50`（`PKG_RELEASE` 50）
- 适用固件：OpenWrt 21.02 ~ 24.10（opkg / `.ipk`）、OpenWrt 25.12+（apk / `.apk`）
- 许可：Apache-2.0

---

## 这是什么、解决什么问题

原生 LuCI 的「网络 → 无线」页是给进阶用户用的多接口、多频段界面；要自己拼一套 802.11s + batman-adv 组网，得手工写 wireless / network / dhcp / firewall 四套配置，还要处理子节点地址分发、信道一致、回程切换、配置同步一堆事。

本插件把这些收进 4 个页面：

- **与原生「无线」页共存，不是替代**——插件只是 `wireless` 配置的另一个写入者。你在「WiFi 快速设置」页改的主节点无线配置，会顺着组网同步链路自动下发到子节点；原生页改也一样生效。
- **相比 WDS / relayd / 纯 802.11r**：走标准 **802.11s mesh point + SAE**（不是 WDS 的私有四地址桥接），用 **batman-adv** 做路径选择（不是 relayd 的 ARP 代理），漫游用 **dawn + 802.11k/v** 引导（不是只靠客户端自己决定）。有线回程直接二层直转、不引入 batman 开销。

---

## 功能总览

### 组网核心

| 功能 | 说明 |
|---|---|
| 一键组网 | 选角色（主/子节点）、填 Mesh ID 与回程密码，保存即自动完成 wireless / network / dhcp / firewall 全套配置，无线重启约 10~20 秒 |
| 802.11s 无线回程 | mesh point 模式，SAE 加密；默认 5GHz 信道 36（非 DFS 段），两端强制同信道，RSSI 接入门限可调（默认 -80 dBm） |
| batman-adv 路径选择 | 强制启用（缺内核模块或 batctl 时 apply 直接拒绝并提示安装命令）；按 TQ 传输质量自动择优，网关模式按角色自动（主节点 server / 子节点 client），无界面开关 |
| 有线回程（B 方案） | 所有物理端口与 bat0 同入 br-lan：插网线 → 网桥 MAC 学习直接转发（零 batman 开销、满线速）；拔线 → bat0 立即接管。跨 mesh 环路由 BLA 抑制，物理口之间的环由 STP 阻塞 |
| 子节点全端口内网化 | WAN/LAN 所有物理口并入 br-lan（swconfig VLAN 与 DSA 均自动处理），删除上行接口、关闭本机 DHCP；子节点自身与下挂终端地址一律由主节点分发（恒 `proto=dhcp`），br-lan MAC 钉成设备主 MAC 防租约漂移 |
| 配置自动同步 | 子节点守护进程每 10 秒经 `http://<主节点>/cgi-bin/mesh-sync` 拉取配置，镜像主节点的 SSID/密码/加密/802.11r；一致时不做任何变更（不重启无线） |
| AP 信道错开 | 主节点信道固定时，各子节点 AP 按注册序号在 2.4G {1,6,11} / 5G 36·149·44·157… 轮转错开，减少同频干扰（回程频段除外，回程必须同信道） |

### 易用性

| 功能 | 说明 |
|---|---|
| 一键加入（配对） | 新节点免手工填参数：主节点点「开放加入」临时起一个配对信号（固件固定 SSID/密码，默认隐藏广播），子节点点「一键加入」连上来领取 Mesh ID 与回程密码并自动应用。窗口默认 10 分钟自动关闭，可改或设为常开；窗口关着时配对信号根本不存在，固定密码不构成风险 |
| 按键一键组网（WPS 键） | 不用进网页：按机身 WPS 键即可组网，**按法即意图**（短按加入 / 中按开窗 / 长按退出）。出厂机开箱直接按即可，详见下文专章 |
| WiFi 快速设置 | 给普通用户的简单无线入口：填 SSID / 选加密 / 选信道 / 选带宽，替代原生无线页的多接口多频段界面。通道宽度用「160 MHz · WiFi 6」这类人话标签，不用 `HE160` 黑话。与原生页共用同一份 `wireless` 配置 |
| 状态页直接选角色 | 组网状态页在未选角色时直接给「设为主节点 / 设为子节点」按钮，不必先跳去设置页；主节点会自动派生 Mesh ID 与回程密码 |
| 能力自检 | 诊断与维护页顶部集中显示缺失项：驱动 mesh point / 完整版 wpad / kmod-batman-adv / batctl / 漫游引导 dawn / umdns。组网必需项缺失 → 红框；组网可用但缺 dawn 或 umdns → 橙框提醒（不影响组网，只是客户端不会被引导切换） |

### 运维与自愈

| 功能 | 说明 |
|---|---|
| 回滚保护 | 应用后开启看护窗口（静态地址 120 秒 / DHCP 子节点 180 秒），到期管理地址不可达则自动还原组网前配置并重启；页面顶部出现「保留新配置 / 立即还原」确认条 |
| 备份与还原 / 退出组网 | 首次启用自动把 wireless / network / dhcp / firewall 备份到 `/etc/mesh-backup/`（关闭再开启不覆盖）；「退出组网」用备份整份覆盖并重启，可完整恢复被删除的 WAN 口。组网状态页与诊断页两个入口，同一套逻辑 |
| 无线漫游自愈 | 随包安装两个幂等自检脚本（`97-wifi-roaming` / `99-dawn-roaming`），默认开机自启 + 每分钟 cron 巡检：前者补齐 AP 的 802.11k 邻居报告 / 802.11v BTM / 802.11r FT，后者校正 dawn 广播地址与 umdns 网络绑定。只在检测到配置漂移时才落盘并重载，配置正常时一轮开销约等于一次 md5sum；脚本带 mesh 守卫，未启用组网时完全静默 |
| 在线安装 / 升级 / 卸载 | 随包落地 `mesh-install`，一条命令升级或卸载，自动保留配置、补扫包管理器删不掉的残留文件 |
| 诊断与维护页 | 能力检测、射频能力表、备份/还原、端口并入内网、日志（可附带 syslog）、软件版本 |

**强依赖**（`Makefile` `LUCI_DEPENDS`，编译安装自动拉齐）：

```
+uclient-fetch +rpcd +curl +jsonfilter +iwinfo +iw
+wpad-mesh-openssl        # 完整版 wpad（wpad-basic / wpad-mini 不带 mesh point）
+kmod-batman-adv +batctl  # batman-adv 路径选择
+luci-proto-batman-adv    # bat0 的 LuCI 协议：网页端才能新建/编辑 proto 'batadv' 的接口
+dawn +umdns              # 无线漫游引导：AP 间交换客户端信号/负载，用 802.11k/v 引导切换
```

---

## 适用硬件与固件

**固件**：OpenWrt 21.02 ~ 24.10（opkg / `.ipk`）、OpenWrt 25.12+（apk / `.apk`）。

**硬件需满足以下能力**（不针对具体机型，按能力判断即可）：

1. **无线驱动支持 802.11s mesh point** —— 由 mac80211 框架提供，绝大多数基于 mac80211 的无线驱动都支持（个别老驱动或厂商私有驱动可能不支持，可在设备上跑 `iw phy | grep -i mesh` 确认）。
2. **有 batman-adv 内核模块与 `batctl` 工具** —— `kmod-batman-adv` + `batctl`。这是路径选择的必需项，缺了 apply 会直接拒绝。
3. **可安装完整版 wpad** —— 需要 `wpad-mesh-openssl`（或 `wpad-openssl` / `wpad-wolfssl`）；`wpad-basic` / `wpad-mini` 不带 mesh point，不能用。

> `kmod-mac80211` 不列入依赖：目标镜像的无线驱动通常已自动选入。列上去反而会让某些 target 因解析不到该包而整包装不上。

---

## 安装

### 方式一：随固件编译（推荐，依赖自动拉齐）

把本目录放进 OpenWrt 源码树后正常编译：

```sh
# 二选一：直接放 package/ 下，或作为 luci feed 的包
cp -r luci-app-mesh <openwrt>/package/luci-app-mesh

make menuconfig    # LuCI → 3. Applications → luci-app-mesh 选 <M>
make package/luci-app-mesh/compile V=s
# 产物：bin/packages/<arch>/base/luci-app-mesh-1.0.0-r50.apk（25.12+）
#                    bin/packages/<arch>/base/luci-app-mesh_1.0.0-r50_all.ipk（24.10-）
```

`LUCI_DEPENDS` 的 12 项依赖由包管理器自动解析，开箱即用；`/etc/config/mesh` 已声明 conffile，升级不会覆盖你的活配置。

### 方式二：免编译直装

**1）先补齐依赖**（按固件包管理器二选一）：

```sh
# OpenWrt 25.12+（apk）
apk update && apk add curl jsonfilter iwinfo iw uclient-fetch rpcd \
    wpad-mesh-openssl kmod-batman-adv batctl luci-proto-batman-adv dawn umdns

# OpenWrt 24.10 及更早（opkg）
opkg update && opkg install curl jsonfilter iwinfo iw uclient-fetch rpcd \
    wpad-mesh-openssl kmod-batman-adv batctl luci-proto-batman-adv dawn umdns
```

> `kmod-batman-adv` 的 kmod 包必须与固件内核版本匹配（用固件自带软件源安装即可）。

**2）安装程序**，二选一：

```sh
# a. 包管理器装编译好的 ipk/apk
apk add --allow-untrusted luci-app-mesh-1.0.0-r50.apk
opkg install luci-app-mesh_1.0.0-r50_all.ipk

# b. 或把整个项目目录传到设备上，运行直装脚本（按 MANIFEST 复制文件、重启 rpcd、启用服务）
sh install.sh
```

装完浏览器打开 `http://<设备IP>/cgi-bin/luci/` → **网络 → Mesh 组网**；菜单没出现就 Ctrl+F5 强刷（必要时重启 uhttpd）。

### 方式三：在线安装 / 升级 / 卸载（`mesh-install.sh`）

装过一次之后脚本会随包落到 `/usr/sbin/mesh-install`，之后直接 `mesh-install upgrade` 即可，不用再去 GitHub 取脚本。

```sh
# 首次：取脚本
curl -fsSL -o /tmp/mesh-install.sh \
  https://raw.githubusercontent.com/xxosdev/luci-app-mesh/main/mesh-install.sh
sh /tmp/mesh-install.sh install

# 升级（默认保留配置）
mesh-install upgrade                       # 取最新
mesh-install upgrade --ver=1.0.0-r50       # 指定版本
mesh-install upgrade --no-keep-config      # 不保留：配置回到出厂默认值

# 卸载（默认保留配置，卸载后自动拷回）
mesh-install uninstall
mesh-install uninstall --no-keep-config    # 连配置/还原点一起清
mesh-install uninstall --revert            # 卸载前先退出组网（推荐在网机器用）

# 离线 / 内网：本地包、源码压缩包或项目目录
mesh-install install --from=/tmp/luci-app-mesh-1.0.0-r50.apk
mesh-install upgrade --from=/tmp/luci-app-mesh-src.tar.gz
mesh-install upgrade --from=/tmp/luci-app-mesh/        # 解压后的项目目录

# 看本机状态（版本 / 包管理器 / 文件落地 / 组网 / 还原点）
mesh-install info
```

**通道策略**：`pkg` 优先 —— 按本机包管理器下载 `luci-app-mesh.apk`（25.12+）或 `luci-app-mesh.ipk`（24.10-）交给包管理器安装；**依赖解析失败或无软件源时自动兜底**到 `src`（下载源码 `tar.gz`，解包后按 MANIFEST 逐项复制）。想强制走源码通道加 `--src`。

| 动作 | 保留配置（默认） | 不保留配置（`--no-keep-config`） |
|---|---|---|
| 升级 | conffile 机制自动保留；若产生 `/etc/config/mesh.apk-new`（或 `-opkg`）会提示 | 装前删除 `/etc/config/mesh`、`/etc/mesh-backup`、`/etc/mesh-state`，装完即出厂值（`enabled=0`、凭证为空） |
| 卸载 | 配置/还原点/状态先存到 `/etc/mesh-config.keep/`，卸载后拷回 | 全部删除，回到从未装过的状态 |

补充选项：`--mirror=<前缀>`（GitHub 不通时走镜像，如 `https://ghfast.top/`）、`--channel=main`（拉主分支源码包）、`--force`（同版本也重装）、`--yes`（非交互，询问取默认值）。

> ⚠ **卸载为什么要"补扫残留"**：本机包数据库里登记的版本可能是随固件编进来的旧版，`apk del` 会按**旧清单**删文件，r30 之后新增的（如 `/etc/rc.wps/10-mesh`）它根本不认识。脚本在包管理器删完后会按内置清单再扫一遍，`mesh-install info` 也会在两者不一致时告警。

---

## 快速上手

1. **主节点**（上网网关）：组网设置 → 角色选「主节点」→ 保存并应用。**Mesh ID 与回程密码可留空**——留空时主节点首次应用会自动生成：Mesh ID 按本机 MAC 派生为 `XxMesh-XXXXXX`（避免与邻居的同款固件重名），回程密码为 16 位随机串；生成后长期固定。也可以自己填（填了就以你填的为准，不会被改掉）。WAN 保持上行不动，DHCP 服务自动确保开启。
2. **子节点（两种方式二选一）**：
   - **一键加入（推荐，不用知道任何密码）**：组网设置 → 角色选「子节点」→ 启用 → 保存并应用；再到组网状态页点「一键加入」，然后去主节点点「开放加入」。子节点会自动连上配对信号、领走 Mesh ID 与回程密码并自动应用。先后顺序无所谓——子节点会一直等（默认 5 分钟）到主节点开窗为止。
   - **手工填**：组网设置 → 角色选「子节点」→ 填**相同**的 Mesh ID 与密码 → 保存并应用。
   两种方式应用后子节点都会删除 WAN 口、全端口并入内网、管理地址改为 DHCP 获取（出厂 `192.168.1.1` 会变化，请到主节点的 DHCP 租约列表找它的新地址）。
3. **等待回程建立**：两台都应用完约 1~2 分钟，组网状态页应看到节点列表、mesh0 对端与 bat0 就绪；子节点 AP 名称/密码此后自动跟随主节点。
4. **（可选）有线回程**：任意一根网线连接两台设备的任意 LAN/WAN 口即可——端口已全部在 br-lan 内，插上就走二层直转，拔掉自动回落无线，无需任何配置。
5. **验证**：终端连接任一节点的 Wi-Fi 或网口，获取的地址应由主节点分发，可直接访问两台的 LuCI；组网状态页拓扑中两节点均在线。

> 常见坑：两端 Mesh ID 相同但**信道不同**时永远 0 对端——本包已强制同信道。单射频设备回程与 AP 共用射频，5G 回程时 2.4G AP 不受影响。

---

## 页面导览

菜单在 **网络 → Mesh 组网**（另有顶层快捷入口 **网络 → WiFi 快速设置**）。

| 页面 | 位置 | 看什么 / 能改什么 |
|---|---|---|
| **组网状态** | Mesh 组网 → 组网状态 | 运行状态卡片、一键加入（配对）卡片（含「退出组网」）、网络拓扑图、节点列表（连接时长/信号/链路质量，离线节点显示最后上报时间） |
| **WiFi 快速设置** | Mesh 组网 → WiFi 快速设置（= 顶层「WiFi 快速设置」） | SSID / 加密 / 密码 / 信道 / 带宽。未组网全部可改；主节点回程频段信道锁定为「跟随回程」；子节点只读 |
| **组网设置** | Mesh 组网 → 组网设置 | 一步组网（角色/Mesh ID/密码/加密/频段/信道/国家码/主节点地址）、一键加入（配对）设置、按键组网（WPS 键）档位、链路控制（RSSI 门限/最大邻居数/离线保留时长） |
| **诊断与维护** | Mesh 组网 → 诊断与维护 | 能力检测（组网前置条件红/橙/绿框）、射频能力表、维护（刷新备份 / 退出组网-还原组网前配置 / 端口并入内网）、软件版本、日志（可附带 syslog） |

---

## 按键一键组网（WPS 键）

不用进网页：按机身 WPS 键即可完成组网。**按法即意图** —— 谁开窗谁是主节点、谁加入谁是子节点，按键顺带把角色写对，所以出厂机开箱直接按就行，不需要先去网页选角色。

| 按法 | 出厂 / 未组网 | 子节点已在网 | 主节点已在网 |
|---|---|---|---|
| **≤4s** | 设为子节点 + 一键加入 ← 开箱自举 | 拒绝（红灯急闪）| 拒绝（红灯急闪） |
| **5~9s** | 设为主节点 + 开窗 10 分钟 ← 开箱自举 | 拒绝 | 窗口已开则关窗，否则开窗 |
| 10~13s | 空档（防手抖） | 空档 | 空档 |
| **14~20s** | 无备份则拒绝 | 退出组网并重启 | 退出组网并重启 |
| >20s | 忽略 | 忽略 | 忽略 |

- **退出档带 10 秒反悔窗口**：松手后红灯急闪，期间再按一次键即取消（`mesh.main.btn_exit_grace`）。
- **实现方式**：只放一个 `/etc/rc.wps/10-mesh` —— `/etc/rc.button/wps` 是个分发器（`for script in /etc/rc.wps/*; do "$script" && break; done`），文件名排最前就能先执行，返回 0 即 break。**不备份、不覆盖任何系统文件**，卸载删掉这一个文件即恢复原样。
- **LED 反馈**：`phone → wlan → power` 自动回退（被拒绝、退出前的反悔期用红灯），动作结束后自动还原这盏灯原来的 trigger。
- **按住期间没有实时提示**：分发器只在松手（released）时回调，拿不到 `pressed`，所以退出档得自己数秒 —— 这是"不接管 `rc.button/wps`"换来的零系统文件改动。
- **副作用**：装上后系统自带 WPS 失效（短按也不再是手机免密连入）。设 `mesh.main.button=0` 即完全让位，按键行为恢复原样。
- **⚠️ 已知风险**：子节点走"加入"档会执行 apply（重建 mesh 回程并重启网络）。**纯无线回程**的节点一旦回程没能重建，就没有有线兜底、会失联 —— 实测遇到过一次。排障：插一根网线到主节点（有线回程立刻恢复通路），或长按 14~20 秒退出组网还原；就算什么都不做，回滚窗口（子节点 240 秒）发现新地址不可达也会自动还原组网前配置。
- **⚠️ 加入档只服务"手里没凭证"的节点**：已在网的子节点按 ≤4s 会被拒绝（`enabled=1` 且 `mesh_id` 非空即视为在网）。因为加入档要先切射频去连配对信号、再 apply 重建网络，正在跑的无线回程会被打断；有线节点能靠回滚窗口救回来，纯无线节点就是直接失联。要重新入网，先长按 14~20 秒退出组网，再按一次。

---

## 工作机制

- **组网拓扑（B 方案，唯一实现）**：所有物理端口与 `bat0` 同入 `br-lan`；`bat0` 的 hard interface 只有无线回程 `mesh0`（mesh0 本身不进网桥）。有线在线时流量走网桥 MAC 学习直达（满线速）；无线经 batman-adv 封包转发。跨 mesh 的环由 batman-adv **BLA**（桥环规避）抑制，物理口之间的环由 **STP**（定时器 4/1/6）阻塞，两者分工不冲突。
- **apply 的执行顺序**：校验参数与能力（驱动 / wpad / kmod-batman-adv / batctl，缺一拒绝）→ 首次备份 4 个配置 → 按角色改写 network/dhcp（子节点删 WAN、全端口进 br-lan、`proto=dhcp`）→ 建 mesh0 + bat0/batmesh + 桥接 → 开回滚保护窗口 → 提交并生效网络（有光口的机型走 `network reload`，其余 `network restart`）+ `wifi reload`。
- **为什么「保存并应用」总是立刻返回成功**：子节点 apply 会把自己的 LAN 改成 DHCP 并重启网络，承载 RPC 应答的连接会被当场掐断——所以 rpcd 后台执行、立即返回 `code=0`。真实结果写入 `/tmp/mesh/last_apply`（tmpfs），设置页表单上方会显示「上次应用：成功/失败」，触发后 8 秒 / 22 秒各回读一次；**重启后记录消失，界面不再显示**。
- **一键加入（配对）为什么用「两把钥匙」**：回程密码既是 802.11s 的 SAE 密钥、也是子节点拉配置的令牌，出厂/恢复出厂的新节点手里没有它，连问都问不到——所以必须另开一条**免鉴权**通道。配对密码是固件里写死的固定值（`XxMesh-Pair` / `xxmesh-pair`），它只在一扇"平时根本不存在"的门上有效：窗口关闭时配对 AP 压根没起来，知道密码也连不上。风险窗口就是开窗的那几分钟，兜底是"得本人在现场开窗"。主节点开窗后，这个配对信号会经现有的 AP 镜像机制**自动同步到所有子节点**，新节点可以就近连信号最好的那个，凭证请求经 bat0 二层域照样回到主节点。
- **配对为什么不能用「第二个 mesh 接口」**：`wpa_supplicant` 一个进程只允许加入一个 mesh group，真机实测第二个 mesh 起来后正式回程立刻被踢（`Avoiding join because we already joined a mesh group`），所以配对通道只能走 AP/STA。配对 STA 还必须是独立 interface 且 `defaultroute=0`：桥进 `br-lan` 会与主节点的配对 AP 成环，走 dhcp 又会抢走默认路由。
- **配置同步协议**：子节点每 10 秒 `GET /cgi-bin/mesh-sync?mac=..&token=<回程密码>&link=wifi|wired` → 主节点校验角色 / enabled / token 后返回 JSON（含 AP 列表、信道、序号）；子节点按序号镜像配置，一致则跳过。链路类型由 station 表与入口端口判定，无线、有线断一个都能继续同步。
- **备份 / 还原 / 回滚语义**：`/etc/mesh-backup/` 只在首次启用时创建，停用再启用**不覆盖**；「退出组网」= 备份整份覆盖回 wireless/network/dhcp/firewall + `enabled=0` + 删备份 + 生效；自动回滚到期不可达时走同一条还原路径。
- **防静默失败**：能力缺失（wpad / kmod-batman-adv / batctl）在诊断页红框明示 + apply 强制拦截；`capabilities` 中 `batctl` 独立于内核模块判定，避免「模块在、工具缺」时界面假绿。
- **漫游配置自愈（为什么用轮询而不是事件）**：本系列固件**不发 procd 的 `config.change` 事件**（命令行 `uci commit` 与 LuCI 的 `uci apply` 两条路径实测都不发），而 LuCI 无线页保存会**重写整段 wireless**，把 `rrm_neighbor_report` / `rrm_beacon_report` 这类它不认识的项直接冲掉。因此 `97-wifi-roaming` / `99-dawn-roaming` 采用每分钟 cron 巡检：配置未变时一轮只做一次 md5 比较即退出，检测到差异才 `uci commit` 并后台重载。两者都是**差异修复器**而非配置器——只补缺失项、不重写已正确的项，所以不会每次巡检都断一次无线。
- **mesh 守卫**：两个脚本都以 `/etc/config/mesh` 的 `enabled` 为总开关。安装时默认 `enable`（开机自启）+ `cron_enable`（每分钟巡检），但在未启用组网的设备上（`enabled != 1`）一律静默退出——**装包本身不会改动无线配置**；卸载时 `prerm` 自动清掉 cron 条目与自启链接。

---

## 常见问题 FAQ

**Q：装完在 LuCI 里找不到菜单？**
先 Ctrl+F5 强刷；还不行就重启 uhttpd（`/etc/init.d/uhttpd restart`），或清 LuCI 缓存
（`rm -f /tmp/luci-indexcache*; rm -rf /tmp/luci-modulecache`）。菜单在 **网络 → Mesh 组网**。

**Q：状态页显示"组网能力不满足"红框？**
去「诊断与维护 → 能力检测」看缺哪一项，按提示装包：
驱动未上报 mesh point（换支持 802.11s 的驱动）/ 缺完整版 wpad（装 `wpad-mesh-openssl`）/
缺 `kmod-batman-adv` + `batctl`。缺 dawn/umdns 只是橙框，不影响组网。

**Q：两台都应用了，但节点列表一直是空的 / 0 对端？**
按顺序查：① 两端 **Mesh ID 与回程密码是否完全一致**（一键加入的不用管，手工填的必查）；
② 两端**回程信道是否相同**（本包会强制，但手工改过 wireless 可能被冲掉）；
③ 两端 `iw dev` 是否有 `mesh0`、`iw dev mesh0 station dump` 有没有对端；
④ `batctl o` 有没有 originator。日志看「诊断与维护 → 日志」。

**Q：子节点管理地址变了，找不到它了？**
子节点应用后管理地址改为 DHCP，去**主节点的 DHCP 租约列表**（网络 → DHCP/DNS → 租约）按 MAC 找。
组网状态页的节点列表也会显示各节点地址。

**Q：一键加入一直"等待主节点开放加入"，最后超时？**
常见两类原因：
① 主节点**窗口没开**或已过期（默认 10 分钟）——重新点「开放加入」；
② 主节点**角色没落盘 / 没 apply**（r46 已修，界面会红框提示 `applied=0`）。
若主节点日志里有 `403`，那是 uhttpd 的 `rfc1918_filter` 拦了备用地址（r45 已修，需两端都升级）。

**Q：怎么彻底退出组网、把设备还原成普通路由器？**
两个入口，效果一样：**组网状态页 → 一键加入卡片底部 → 退出组网**，或
**诊断与维护 → 退出组网-还原组网前配置**。会还原到备份时刻的 WiFi 名称密码、
防火墙、DHCP、LAN 地址，清除 Mesh 凭证，管理地址可能变化、页面会短暂断开。
⚠ 主节点退出后所有子节点都会断开，需要各自重新加入。

**Q：怎么完全卸载插件？**
`mesh-install uninstall`（默认保留配置，卸载后自动拷回）。要连配置一起清加 `--no-keep-config`；
在网机器建议先 `mesh-install uninstall --revert`（卸载前先退出组网）。

---

## 目录结构

```
luci-app-mesh/
├── Makefile                                  # OpenWrt feed 打包（依赖 / conffiles / postinst）
├── MANIFEST                                  # ★ 文件清单单一真相源（源路径|目标路径|权限）
├── install.sh                                # 免编译直装（按 MANIFEST 安装）
├── mesh-install.sh                           # ★ 在线安装/升级/卸载（GitHub Release 或本地包）
├── README.md                                 # 本文档
├── CHANGELOG.md                              # 版本变更记录
├── .github/
│   ├── workflows/release.yml                 #   CI：24.10 SDK→ipk ‖ 25.12 SDK→apk
│   └── scripts/check-manifest.sh             #   校验 MANIFEST / Makefile / 内置清单一致
├── htdocs/luci-static/resources/view/mesh/   # LuCI JS 界面
│   ├── overview.js                           #   组网状态
│   ├── settings.js                           #   组网设置
│   ├── tools.js                              #   诊断与维护
│   ├── wifi.js                               #   WiFi 快速设置
│   └── mesh.css
└── root/
    ├── etc/config/mesh                       # 默认 UCI 配置（conffile 保护，升级不丢活配置）
    ├── etc/init.d/mesh                       # procd 守护服务（S99，respawn）
    ├── etc/init.d/97-wifi-roaming            # 漫游自检：补齐 AP 的 802.11k/11v/11r（开机自启 + cron）
    ├── etc/init.d/99-dawn-roaming            # 漫游自检：校正 dawn 广播地址 / umdns 绑定
    ├── etc/hotplug.d/iface/30-mesh-bat-mtu   # 接口 up 时事件驱动补 bat0 hardif MTU
    ├── etc/uci-defaults/40-luci-app-mesh-roaming  # 预装固件首次开机补 cron/自启（跑完自删）
    ├── etc/rc.wps/10-mesh                    # WPS 按键一键组网
    ├── etc/nginx/conf.d/mesh-sync.locations  # Kwrt 等 nginx+uwsgi 固件专用（uhttpd 忽略）
    ├── usr/sbin/meshctl                      # 核心命令行
    ├── usr/sbin/mesh-install                 # 随包落地的在线安装脚本（= mesh-install.sh）
    ├── usr/libexec/mesh/functions.sh         # 全部组网函数库（apply / revert / 同步 / 探测…）
    ├── usr/libexec/mesh/version              # ★ 真实已装版本号
    ├── usr/libexec/rpcd/mesh                 # ubus 插件：LuCI JS ↔ meshctl 的桥 + 命令白名单
    ├── usr/share/luci/menu.d/luci-app-mesh.json
    ├── usr/share/rpcd/acl.d/luci-app-mesh.json
    └── www/cgi-bin/mesh-sync                 # 主节点配置下发端点（CGI，返回 JSON）
```

> **为什么有 `MANIFEST`**：Makefile 的 `Package/install` 段与 `install.sh` 曾经是两份各自维护的清单，结果 `install.sh` 长期漏装 3 个文件（`rc.wps/10-mesh` 按键组网、`uci-defaults/40-...`、nginx conf）—— 走直装的机器上"按键一键组网"根本不存在。现在 `install.sh` 只认 `MANIFEST`，CI 里 `check-manifest.sh` 会把它与 Makefile、以及 `mesh-install.sh` 的内置清单三方比对，不一致直接红。
>
> **为什么有 `version` 文件**：包数据库的版本会撒谎 —— 真机上 apk 记的是随固件编进来的旧版本，实际文件早被手动覆盖，"要不要升级"因此判不准。该文件随每次安装/升级被覆盖，永远等于真实落地版本。

`meshctl` 子命令：`apply`（应用组网）、`status`（状态 JSON）、`diag`（诊断输出）、`sync`（手动同步一次）、`daemon`（守护循环）、`revert`（退出组网-还原组网前配置）、`confirm_rollback`（保留新管理地址）、`port_bridging`（端口并入内网）、`set-role`（只落角色配置不应用）、`button`（WPS 按键分档动作）、`pair-open` / `pair-close` / `pair-status` / `pair-join`（配对窗口与加入）、`backup-refresh`（以当前配置重建还原点）、`log`（读日志，可附 syslog）、`wifi_ensure`（保存无线后补一次 AP 自愈）。

---

## 运维备忘

- ★ **升级不能只换 `meshctl`**：包里有 21 个文件（见 `MANIFEST`），真机核对时发现过某些节点的 `meshctl`、`mesh-sync` 落后（只单独 wget 过其中几个）。核对办法：本地 `md5sum` 全部文件，设备上逐个 `md5sum` 比对。用 `mesh-install upgrade` 可避免这个问题。
  - `/etc/config/mesh` **各节点本就不同**（含自己的 role / 凭证），不要覆盖。
  - `/etc/uci-defaults/40-luci-app-mesh-roaming` 在设备上 MISSING 是**正常的**，OpenWrt 首次启动跑完就会删掉这个文件。
- ★ **关于 LuCI「迁移配置」弹窗（r39 已治本）**：r39 起本工具建的无线段全是具名段（`xxmesh_*`）、接口成员按固件语法写 `device`，**不会再因为本工具的配置弹迁移**。固件自带 / 用户自己建的匿名段仍会弹，那与插件无关；即便用户点了迁移把段名改掉，本工具也能靠 `mesh_managed=1` 标记把自己建的段找回来（旧版本则会因此失联：状态文件里的名字失效 → 每轮新建一段）。
- **一次性整理命令**（只给"从旧版本升级上来的机器"用，新装机器不需要）：

  ```sh
  . /usr/libexec/mesh/functions.sh
  # 1) 回程段 + 配对 AP 段：匿名段 -> 具名段
  for p in "mesh-iface:xxmesh_backhaul" "pair-section:xxmesh_pair_ap"; do
      f=${p%%:*}; b=${p##*:}; s=$(cat /etc/mesh-state/$f 2>/dev/null)
      [ -n "$s" ] || continue
      n=$(mesh_wifi_iface_rename "$s" "$b") && [ -n "$n" ] && echo "$n" > /etc/mesh-state/$f
  done
  # 2) 各射频的 AP 镜像段
  for f in /etc/mesh-state/ap-created-*; do
      [ -f "$f" ] || continue
      r=${f##*/ap-created-}; out=""
      for s in $(cat "$f"); do out="$out $(mesh_wifi_iface_rename "$s" "xxmesh_ap_$r")"; done
      echo $out | tr ' ' '\n' | grep . > "$f"
  done
  # 3) batmesh：ifname -> device（仅 21.02+ ；19.07 及更早跳过这一步）
  uci set network.batmesh.device=$(uci -q get network.batmesh.ifname)
  uci -q delete network.batmesh.ifname
  uci commit wireless; uci commit network; wifi reload
  ```

---

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。

## 变更记录

完整版本历史见 **[CHANGELOG.md](CHANGELOG.md)**。最近三版：

- **r50** — 新增「WiFi 快速设置」页（人话带宽标签）；能力检测移到诊断与维护；标签栏加 WiFi 快速设置；节点列表连接时长换算成「天/小时/分」。
- **r49** — 配对信号默认隐藏广播（不广播 SSID），新增 `main.pair_hidden` 开关。
- **r48** — 配对链路失败可追溯：两端补日志点 + 限流 + 超时后一次性状态码探测。
