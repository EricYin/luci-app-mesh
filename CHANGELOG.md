# 变更记录

本文件按**版本倒序**排列（最新在上），记录 luci-app-mesh 的每一次变更。
`r<版本>` 与 `Makefile` 的 `PKG_RELEASE` 一一对应；安装与使用说明见 [README.md](README.md)。

格式：`## r<版本>（YYYY-MM-DD）` + 一句话摘要 + 要点列表。

---

## r51（2026-10-08）
修复**子节点 apply 后拿不到 DHCP 地址、240 秒后被自动回滚**的 100% 复现 bug。

根因：batman-adv 的 `gw_mode != off` 时，客户端发出的 DHCP 请求会被内核当作"交给网关"
处理（`batadv_send_skb_via_gw`），而本插件是**单主节点 + br-lan 二层桥接**，全网没有真正的
出网网关 —— 网关表恒空 → 请求整包丢弃（`TX_DROPPED++`）→ 子节点拿不到租约 → 回滚。
主节点侧的触发点：`cmd_apply` 里"主节点无默认路由 → `server` 降 `client`"的降级逻辑，
在开机后前约 5 分钟（默认路由尚未建立）内被命中，把 `bat0.gw_mode=client` **固化**进
`/etc/config/network`，而守护进程此后不会重算 → 错值永久留存，重启也不纠正。

- **网关模式改为恒 `off`（方案 A）**：DHCP 请求/应答回到广播泛洪，不依赖任何网关收敛。
  实测：改 `off` 后 2 秒内拿到租约（对比 bug 态主节点 dnsmasq 全程 0 条记录）。
- 新增 `mesh_bat_gw_effective()`（`functions.sh`）作为**唯一的网关模式解析入口**，
  取代原先散在 5 处的同款逻辑（`cmd_apply` / 状态页 / `meshctl status` / `mesh-sync`）。
  该函数当前恒返回 `off`，签名保留角色参数 —— 后期做"多网关开关"（方案 C）时只需改
  函数体，所有调用方零改动。
- **删除** `cmd_apply` 中"主节点无默认路由 → 降 `client`"的降级逻辑（本次 bug 的元凶）。
- `main.batman_gw` 默认值与归一化目标由 `auto` 改为 `off`（升级设备下次 apply 自动纠正）。
- `mesh_batman_apply()` 本身未改动 —— 它早已参数化，传 `off` 天然可用。
- 界面代码未改动：`overview.js` 原本就会过滤 `gw_mode === 'off'`，不显示 `· gw` 后缀。

---

## r50（2026-10-07）
新增**「WiFi 快速设置」**页（菜单：网络 → WiFi 快速设置，与原生「无线」页并存、共用同一份
`wireless` 配置）。给普通用户一个"填名字 / 选加密 / 选信道"的简单入口，替代原生无线页那套
面向进阶用户的多接口多频段界面。

- 字段：双频合一（默认不勾，勾上后 2.4G/5G 合并为单个名称）、SSID、加密方式（默认
  WPA2-PSK）、密码、信道、通道宽度。功率与国家代码**不在此页**（功率本就不全网同步，
  国家代码在「组网设置」里）。
- 通道宽度用**人话标签**（如「160 MHz · WiFi 6」）替代原生 `htmode` 黑话
  （`HE160` / `VHT80` / `HT20` …），由 `htmodeParse()` / `htmodeLabel()` 把
  「制式代际 + 带宽」拆成两段可读文字。
- 它**不引入任何新的状态层**：就是 `wireless` 配置的另一个写入者。组网的同步/镜像链路
  本来就在读 `wireless`（AP 段的 ssid/enc/key、radio 的 channel/htmode），所以这里写进
  主节点的无线配置会自动下发到子节点，无需改动 mesh 的同步代码。
- 组网联动：未组网时全部可改（就是个普通 WiFi 页）；主节点上**回程频段的信道锁定为
  「跟随回程」**（该频段与回程共用同一射频，改了会拆组网，要改去「组网设置」）；
  子节点上 SSID/加密/信道/带宽全部只读（每 10 秒被主节点镜像覆盖）。
- 后端：`meshctl status` 的 `radios[]` 新增 `htlist`（本机该射频真实支持的 htmode 列表），
  页面据此出「通道宽度」下拉，避免写进不支持的带宽导致热重载 -122 把 AP 打掉。
- 后端：新增 `meshctl wifi_ensure`（+ rpcd 白名单）——本页保存走 `uci.apply()` 不经过
  apply/sync 那条自带兜底的路径，而热重载在"AP 与 mesh0 共用同一 radio"的 mt76 设备上
  可能把 AP 留在 disabled 且不自恢复；保存后异步补一次 `mesh_wifi_ensure_aps_up`
  （只读 sysfs，正常零开销，坏掉时才冷重启该 radio）。
- `luci/uci.js` 的 `apply()` 不会替你 `save()`，本页保存顺序是 `uci.save()` → `uci.apply()`；
  且只在值真的变了时才写 UCI（避免相同值也留下变更记录、白白重载无线）。

### r50 后续（UI 调整，仍属 r50，未再升版本号）
- **能力检测从「组网状态」移到「诊断与维护」**：它回答的是"这台设备到底能不能组网"，
  属排查信息，与诊断页的射频能力表同类，现排在诊断页最前；组网状态页只保留
  "本机角色没落盘"这个状态类红框。
- **标签栏新增「WiFi 快速设置」**（在「组网状态」之后），实现为
  `{"type":"alias","path":"admin/network/wifi-quick"}` 的真跳转，与顶层
  `网络 → WiFi 快速设置` 是同一个页面。
- **网络拓扑去掉正方形外框**（`.mesh-topo-svg` 的 `border` 注释掉）。
- **节点列表「连接时长」换算成人话**：由秒改为「天 / 小时 / 分」（精确到分，不显示秒），
  不足一分钟显示「不足 1 分」。纯前端换算，后端 `p.connected` 仍是秒。

---

## r49（2026-10-07）
配对信号默认**隐藏广播**（不广播 SSID），并做成可配置。

- 背景：配对 AP 此前是个正常广播的 `XxMesh-Pair`，附近设备在 WiFi 列表里看得见，
  容易被好奇尝试、刷日志。真正的防护本是窗口时限（默认 10 分钟），隐藏只是降噪。
- 主节点 `mesh_pair_ap_add` 建配对 AP 时按 `main.pair_hidden`（默认 1）写 `hidden`。
- 子节点 `cmd_pair_join` 建配对 STA 时加 `scan_ssid=1` —— 隐藏网络的 beacon 里
  SSID 为空，wpa_supplicant 不主动发带 SSID 的 probe request 就永远关联不上。
- 子节点镜像主节点 AP 列表时，对**配对 AP**（SSID+密码命中本机配对凭证）跟随
  `pair_hidden` 写 `hidden`。★ 只写**工具自建段**（`mesh_managed=1`）：
  镜像时第 1 个 AP 会复用原生/用户段，往那里写 hidden 会在关窗后残留、把用户自己的
  AP 永久隐藏 —— 跳过原生段即根治（代价：配对 AP 独占某射频这种少见场景下，
  子节点那份不隐藏，仅观感不一致，不影响功能）。
- 隐藏不影响配对流程：`mesh_pair_scan_channel` 用的是定向扫描（`iw dev scan ssid`），
  本来就能发现隐藏网络。
- 新增 UCI 选项 `main.pair_hidden`（默认 1）+ 设置页开关「隐藏配对信号」。

---

## r48（2026-10-07）
让**配对链路的失败可追溯** —— 此前"子节点领不到凭证"这件事在两端日志里**几乎完全静默**，
排查只能靠猜。

- 背景（真机踩过两次）：r45 那个 403、以及 r46 那次"子节点领到凭证却组不上网"，
  定位时都吃过同一个亏 —— 主节点日志**只有成功发凭证那一行**，所有失败分支
  （没启用 / 角色不对 / 窗口没开 / 密码不符 / MAC 非法）**一律不记日志**，
  真正的原因只存在于 HTTP 响应体里，被子节点的 `curl -s` 一收一丢。
  子节点侧更彻底：整个 `cmd_pair_join` **一条 `mesh_log` 都没有**，全走 stdout，
  被 rpcd 重定向进 `/tmp/mesh/pair.log`（tmpfs，每次配对前清空、重启即失）。
  结果就是：主节点看起来"什么都没发生"，子节点只说"等待超时"，中间那道 403
  只在 uhttpd syslog 里露一次脸。
- 主节点 `mesh-sync` 补 6 个日志点（join 分支的 not_master / window_closed；
  基本校验的 disabled / role_unset·not_master / 密码不符 / MAC 非法），
  全部带**来源地址与 MAC**（`REMOTE_ADDR`，不可被 XFF 伪造）。
  这里**不做来源限流**：这些虽会被重试请求反复打到，但都属于"配置不正常"的信号
  （正常流程几秒内就领走了），日志量可控；限流反而会掩盖首次失败原因。
- 子节点 `cmd_pair_join` 补 7 个日志点：开始领取（候选地址/网卡/本机配对地址/是否撞号/
  超时秒数）、领取未成功、超时探测、超时汇总、凭证不完整、已领取凭证、撞号改备用地址。
- **限流（方案 A）**：重试循环 10 秒一轮、每轮 N 个候选，不节流的话一次 300 秒超时能刷
  100+ 条。复用循环里现成的 `waited` 计数器，只在**首轮 + 每 60 秒**记一次失败详情 ——
  不引入任何新 state 文件，也不改控制流，一次 300 秒超时最多 6 组。
  取舍：失败原因若在 60 秒内变化会被漏掉，由循环结束后的"超时汇总 + 一次性探测"兜底。
- **超时后一次性状态码探测**：循环正常路径坚持**不加任何额外开销**，只在超时后对每个候选
  做一次 `curl -o /dev/null -w '%{http_code}'`，把状态码钉进日志：
  `000`=连不上/超时，`403`=被 uhttpd 的 rfc1918_filter 拦（r45 那类，报 404 的场景），
  `404`=CGI 路径不对，`200` 但 `ok=0`=主节点明确拒绝（原因见上一行 lastfail）。
- ⚠ **`-o /dev/null -w` 绝不能进重试循环**：实测（子节点 curl 8.22.0）
  `-o /dev/null` 会**丢掉响应体**，`jsonfilter @.ok` 拿不到值，整条配对链路直接崩。
  只在"这一遍本来就不需要响应体"的超时探测里用才是安全的。

---

## r47（2026-10-07）
在「一键加入（新节点免配置入网）」区块补上**「退出组网」**，让这个区块成为完整生命周期
（在这里进、在这里出），不必再跑去「诊断与维护」页找按钮。

- 背景：退出组网的能力其实一直都有 —— WPS 键长按 14~20 秒（带 10 秒反悔窗口）、
  「诊断与维护」页的「还原组网前配置」。但「一键加入」区块**只有入口没有出口**，
  用户在这个区块把节点加进网，想退出时得换一个页面、找一个名字不像"退出"的按钮，
  认知断层明显。
- 位置：组网状态页「一键加入」卡片底部，与上方主操作按钮之间用**虚线隔开**
  （退出是不可逆的破坏性操作，视觉上必须拉开距离防误点）。
- **显示条件刻意收紧**，只有"真的组上网且手上有还原点"才出现：
  `role_set=1` + `enabled=1` + `applied=1`（r46 新增字段）+ `mesh_id` 非空 +
  `backup_exists=1`。理由：刚设完角色还没 apply 的中间态退出没有意义；
  没有备份时 `cmd_revert` 只会报"未找到组网前备份"，提前不显示比让用户点完吃报错友好。
- **主/子节点分别确认**：
  - 子节点：说明会还原到备份时刻的 WiFi 名称密码、防火墙、DHCP、LAN 地址，
    清除 Mesh 凭证，管理地址可能变化、页面会短暂断开。
  - 主节点：**额外警告"退出后所有子节点都会断开，且需要各自重新加入"** ——
    主节点退出是全网事件，不能和子节点同等对待。
  - 两者都会显示**备份创建时间**，并明确"该时刻之后的所有修改都会丢失"。
- 为什么只用 confirm、不复制 WPS 那套"反悔窗口"：反悔窗口是为了弥补**物理按键没有
  确认对话框**；网页上 confirm 已是标准手段，再套一层倒计时是过度设计。
- 后端**零改动** —— 直接复用 `meshctl revert`（与维护页同一个命令、同一套清洗逻辑：
  清 enabled/mesh_id/mesh_key/master_addr/**role**、按内容清扫 mesh 与配对 AP 段、
  删状态目录、删备份本身）。生效方式也是现成的"逐项 reload + 校验，起不来才兜底 reboot"。
- 配套：维护页按钮同步改名为「**退出组网-还原组网前配置**」，并在提示里注明
  "与组网状态页配对区块的「退出组网」是同一个操作"，消除两处叫法不一致的困惑。

---

## r46（2026-10-07）
修**「点「成为主节点」后子节点照样入不了网」**——`set-role` 只写配置、从不应用，
导致主节点的 mesh0/bat0 根本没被创建。

- 现象（真机复现）：主节点点「成为主节点」→ 点「开放加入」→ 子节点点「一键加入」。
  配对 AP 正常起来，子节点**也真的领到了凭证**（日志有
  `配对：<mac> 领取了组网凭证`），界面显示「本轮已加入 **1** 台」，但**始终组不上网**。
- 证据：主节点上 `iw dev` 只有 `phy1-ap0/phy0-ap0/pair0`，**没有 mesh0、没有 bat0**；
  `batctl o` 报 `interface bat0 is not present`；`uci show network` 的 br-lan 成员里
  没有 bat0。日志只有一条 `角色设置：master（enabled=1，未应用）`，
  **全程没有任何一次 apply 记录**。
- 根因：`cmd_set_role` 设计上"只写 UCI、绝不应用"（理由是子节点没凭证，立刻 apply 必失败）。
  这理由对**子节点**成立，对**主节点**不成立 —— 主节点的 mesh_id / 回程密码在同一个
  函数里就当场派生好了，apply 所需的一切都已就绪。结果就是子节点拿着一张"门票"，
  进场发现场馆还没盖。
- 对照：WPS 按键路径**早就有这个兜底** —— `cmd_button_open` 里有
  `if [ -z "$(mesh_mesh_ifaces)" ]; then cmd_apply; fi`，按键加入走
  `cmd_pair_join --apply`。**唯独网页这条路径漏了**，所以按键比网页更"一键"。
- 修法：`cmd_set_role` 的**主节点分支**写完 UCI 后直接 `cmd_apply`（先 `mesh_unlock`
  再 apply —— apply 自己会抢同一把锁，握着锁去调它必然死锁）。子节点分支保持原样。
- 配套：
  - `cmd_status` 新增 `"applied"` 字段（有 mesh 回程接口 = 1），让"只写了配置没应用"
    这个中间态在界面上可见，而不必去翻日志。
  - 主节点已开窗但 `applied=0` 时，配对区块顶部弹红框提示。
  - 「本轮已加入 N 台」下方补注解：该计数**只表示领走凭证的台数，不代表组网成功**。
  - 「成为主节点」按钮改名并说明会**重载网络、可能中断 10~30 秒**；前端在 apply
    期间显示"正在应用…"模态框，超时也如实提示"可能正在重载网络"，不误报为失败。
- ⚠ 与 r45 的关系：r45 修的是"凭证领不到"（403），r46 修的是"凭证领到了但没接口承接"。
  两个问题**同时存在**且互相掩盖 —— r45 修好后剩下 r46 这层。

---

## r45（2026-10-06）
修 r35 备用地址选错网段导致的**「配对 STA 连上了、DHCP 拿到地址了，却一次凭证都领不到」**。

- 现象（子节点恢复出厂 + 主节点默认配置，必现）：子节点配对 STA 正常关联（`iw dev pair0
  station dump` 可见）、DHCP 拿到 `192.168.1.x`，但每 10 秒发的
  `GET http://192.0.2.1/cgi-bin/mesh-sync?action=join&mac=..` **全部返回 `403 Forbidden`**，
  一直重试到 `pair_wait`（默认 300 秒）超时，加入失败。
- 根因：r35 的备用地址 `192.0.2.1` 属 RFC 5737 TEST-NET-1，**不是 RFC1918 私网**。
  而主节点 uhttpd 默认 `option rfc1918_filter '1'`（防 DNS rebinding），其判定正是
  **「源 IP 属 RFC1918 + 目的地址不是私网 → 拒绝」**：
  源 `192.168.1.158`（私网）→ 目的 `192.0.2.1`（被当 public server address）→ 403。
  uhttpd 二进制内的原话：`Rejected request from RFC1918 IP to public server address`。
  403 是 uhttpd 在 CGI 之前返回的，脚本根本没被执行 —— 所以改 CGI 无解。
- **与固件版本无关**：r39 固件实机对照验证，同样 403、同样无限重试。
  （`uhttpd` 配置在两版固件里一致。）
- 触发条件：**子节点内网与主节点撞号**（恢复出厂必然 `192.168.1.1` → 必撞）。
  非撞号场景不走备用地址，故不受影响 —— 这也解释了"以前测试没暴露"。
- 修法：`MESH_PAIR_ALIAS` 改用 RFC1918 私网地址 `10.255.255.1`（属 `10.0.0.0/8`，
  家用设备极少用，单挂 `/32` 不引入路由）。"私网→私网"uhttpd 不再拦。
  实测：私网源访问 `10.255.255.1` → `200 OK`，访问 `192.0.2.1` → `403`。
- ⚠ 升级注意：主/子节点**都要**升到含 r45 的版本。只升一端时备用地址不一致，
  撞号场景仍会失败（非撞号场景不受影响）。
- 验证结果：改后 `200 OK` → `配对：<mac> 领取了组网凭证` →
  `wpa_supplicant: mesh0: mesh plink with .. established` → `iw dev mesh0 station dump`
  显示 `mesh plink: ESTAB`；`batctl o` originator 满分 255。

---

## r44（2026-10-06）★ 单一文件清单 + 在线安装/升级/卸载 + CI 编译

新增在线运维能力与两条根因修复，不含组网逻辑改动。

**① 新增 `MANIFEST` 作为文件清单单一真相源**
- 此前 Makefile 的 `Package/install` 段与 `install.sh` 是两份各自维护的清单，
  结果 `install.sh` **长期漏装 3 个文件**：`etc/rc.wps/10-mesh`（r30 按键一键组网）、
  `etc/uci-defaults/40-luci-app-mesh-roaming`（r23 预装补偿）、
  `etc/nginx/conf.d/mesh-sync.locations`。走直装的机器上按键组网根本不存在。
- 现在 `install.sh` 只按 MANIFEST 安装；CI 的 `check-manifest.sh` 把
  **MANIFEST / Makefile install 段 / mesh-install.sh 内置清单三方比对**，不一致直接红。

**② `install.sh` 不再用 `install` 命令**
- 目标固件的 busybox **没有编进 `install` 这个小程序**（三台实测
  `command -v install` 全空），原写法在这些机器上直接 `install: not found`。
  改用 `mkdir -p` + `cp` + `chmod`。
- 覆盖前先 `/etc/init.d/mesh stop`：`/usr/sbin/meshctl` 带 shebang，内核以 execve
  执行它，进程在跑时覆盖会 **ETXTBSY**。

**③ 新增 `/usr/libexec/mesh/version`**
- 包数据库的版本会撒谎（真机 apk 记 `1.0.0-r23`，实际文件 r43+），
  "要不要升级"因此判不准。该文件随每次安装/升级覆盖，永远等于真实落地版本。

**④ 新增 `mesh-install.sh`（随包落地为 `/usr/sbin/mesh-install`）**
- `install / upgrade / uninstall / info` 四个子命令，细节见 README「方式三」。
- 通道：pkg（apk/ipk）优先，依赖解析失败或无源自动兜底 src（源码 tar.gz）；
  也支持 `--from` 指定本地包/压缩包/目录。
- 升级默认保留配置；卸载默认保留（存 `/etc/mesh-config.keep/` 后拷回）、
  在网时询问是否先退出组网、包管理器删完再按内置清单补扫残留。
- 下载走 GitHub Release 固定名 URL，`--mirror` 可换镜像，下载后校 sha256（不一致即放弃）。

**⑤ 新增 GitHub Actions（`.github/workflows/release.yml`）**
- 两条并行 SDK：`build-ipk`（24.10.4 SDK，`CONFIG_USE_APK=n`）与
  `build-apk`（25.12 SDK，`CONFIG_USE_APK=y`）—— **包格式由 SDK 决定，不是开关**，
  同一个 SDK 出不了两种格式。
- 本包 `LUCI_PKGARCH:=all`，一套 x86/64 SDK 覆盖全部设备架构，无需多架构矩阵。
- 产物：版本名 + **固定名副本**（脚本可用 `latest/download/luci-app-mesh.apk`
  稳定取包）+ 源码包 + `sha256sums.txt`；tag 与 Makefile 版本不一致时 CI 直接报错。

**真机验证（192.168.1.245，src 通道完整闭环）**
- `info` 正确报出"文件版本 r43 / 数据库版本 r23 不一致"并告警。
- 安装：19 个文件写入 + `/etc/config/mesh` 按现有配置保留 → `info` 20 存在 / 0 缺失。
- 卸载：4 份配置存入 `/etc/mesh-config.keep/`，`apk del` 后又**补删了 4 个旧清单
  不认识的残留文件**，配置自动拷回，`enabled=1 / role=client / mesh_id` 全部保留。
- 重装恢复：20/0，`mesh0` 对端 2 个，守护进程与 97/99 的 cron 条目均恢复。

---

## r43（2026-10-06）★ 真根因
修 `rpc.declare` 的 `expect` 用法错误 —— 日志区拿不到内容、按钮提示变占位文案、
「上次应用结果」永久隐藏，都是同一个原因。

- **LuCI 的 `expect` 不是"缺省值填充"，而是按字段取值**（`rpc.js` 原文）：
  ```js
  if(req.expect){for(const key in req.expect){if(ret!=null&&key!='')
      ret=ret[key];if(ret==null||type.call(ret)!=type.call(req.expect[key]))
      ret=req.expect[key];break;}}
  ```
  即：**取 `expect` 的第一个 key，把返回值替换成 `ret[key]`，然后 `break`**。
  所以 `expect: { stdout: '' }` 会让调用直接 resolve **`stdout` 字符串**，
  而不是 `{code, stdout}` 对象 —— 调用方再写 `res.stdout` 恒为 `undefined`。
- 写法统一改成 **`expect: { }`**（没有 key → 不做替换 → 返回完整对象）。
  受影响 6 处：`tools.js`×2、`overview.js`×2（exec / pair）、`settings.js`×2（exec / last_apply）。
- 实测影响（node 复现 LuCI 逻辑 + 真实响应）：
  | 写法 | declare 返回 | 取到 |
  |---|---|---|
  | `expect:{stdout:''}` + `res.stdout` | string | **0 字符** |
  | `expect:{}` + `res.stdout` | object | 109 字符 ✅ |
  | `last_apply` 修复前 | — | 解析成 `code=2` → 整块 `display:none` |
  | `last_apply` 修复后 | — | `code=0` → 正常显示 ✅ |
  → 也就是说：**设置页「上次应用结果」此前一直是失效的（永远隐藏）**，不是"没有记录"。
- `tools.js` 另加 `pickStdout(res)`：字符串 / 对象两种形状都认，避免以后再被同类问题坑。

---

## r42（2026-10-06）
修维护页日志区「接口有返回，页面却一直显示暂无日志记录」。

- **根因不在后端**：实测 HTTP JSON-RPC（`mesh` / `exec` `cmd=log`）返回 `code=0`、
  751 字符 stdout，链路完好；问题在于前端把「没取到」和「日志为空」显示成同一句。
- **`runCmdArg` 不再把失败静默成空串**：原来 RPC 失败只弹一条通知、返回 `null`，
  界面拿到空值就写「暂无日志记录」，和"确实没日志"长得一模一样，排查极其费劲。
  现在返回 `{ok,text,code,err}`：失败把错误原因**直接写进日志框**（同时 console.error），
  空日志单独显示「日志为空或文件不存在：/tmp/mesh/mesh.log」。
- **写入时按 id 重新定位日志框**：本页 15 秒轮询重渲染一次，每次 render 都会新建一个
  `<pre>`；闭包里那个 `logBox` 在异步返回时可能已经不属于文档，写进去页面毫无变化
  —— 表现就是"接口有返回、页面不动"。改成 `document.querySelectorAll('#mesh-log-box')`
  取最后一个（= 当前页面上的那个），「复制 / 下载」按钮同样改走这个定位。

---

## r41（2026-10-06）
备份机制的三处小改 + 维护页新增「刷新备份」按钮和日志区。

- **`mesh_backup_once` 只在"未入网"时才重建还原点**（原来是有备份就永不刷新）。
  真机 .219 的备份停在两天前，那时退出组网会把用户后来改的 WiFi 名称密码、防火墙、
  DHCP 全退回去。判据：已有备份**且** `main.enabled=1`（在网）才保留；未入网就重建。
  未入网时配置天然干净，重建不会把组网状态固化进去。
- **`mesh_do_revert` 清洗 role**：残留 `client` 的后果最严重 —— 这台机器下次想当
  主节点时，apply 会直接走子节点分支（删 wan 接口、WAN 口并进 br-lan、LAN 改 DHCP），
  而它本该是出口，且**静默发生不报错**。代价只是下次组网要在状态页点一下选角色。
- **`mesh_do_revert` 清理还原回来的 mesh 段**：备份可能是在"已开过窗"状态下建的，
  整份拷回会让配对 AP 段复活（公开密码长期广播）。按**内容**认定清理（mode=mesh、
  配对 AP 特征），不认段名，兼容 r39 之前的匿名段。network 侧不用清 —— 实测三台
  备份都不含 bat0/batmesh。
- **新增 `meshctl backup-refresh` / `mesh_backup_refresh()`**：以当前配置为底重建
  还原点并剔除组网相关内容。三步保证安全：先复制到临时目录净化（失败绝不动真实
  备份）、覆盖前留存 `/etc/mesh-backup.prev`、闪存不足 256KB 直接放弃。
  ⚠ 全程只用 `uci delete` / `del_list`，**绝不 `uci set` 任何 ipaddr**（这台固件是
  `list ipaddr 'x/24'` 写法，`uci set` 会写掉 /24 前缀导致整机失联 —— 血的教训）。
- **新增 `meshctl log [行数] [--syslog]`** 与维护页日志区：200 行、可勾选附带
  logread、刷新/复制/下载（复制下载纯前端，无需后端改动与额外权限）。
  rpcd 白名单已加 `backup-refresh`；`log` 因需带参数单独走分支。
- 维护页显示备份创建时间；还原按钮的确认文案改掉过期的"路由器将重启"。

---

## r40（2026-10-06）
修「**启用主节点 = PON 断网**」——光口上行机型上，一启用组网外网就全断，PON 状态
页显示「线路停止」。

- **根因**：apply 收尾无条件跑 `/etc/init.d/network restart`，而它的 `stop_service()`
  是 `wifi down` + **`ifdown -a`**（关闭**全部**接口）+ 重启 netifd —— **pon0 光口也
  在里头**。pon0 被 down/up 后 airoha-xpon 驱动重启注册状态机（真机实测 dmesg：
  `XG-PON RX started, irq=53, ONU-ID=1023 (invalid)`），而驱动要求「carrier 直到 O5
  才 up」，注册完成前 wan(pon0) 拿不到地址 → 外网全断、状态页「线路停止」。
  对照实验：`ubus call network reload` 后 dmesg 无任何 PON 事件、路由不变。
- **排除的嫌疑**：不是「把光口并进内网」。实测 `mesh_wan_devices` 把 pon0 正确识别为
  上行口，`mesh_lan_ports` 排除它，br-lan 成员里没有 pon0（物理端口枚举只扫
  `lan*/wan*/eth*`，pon0 不匹配）。
- **改法**：新增 `mesh_net_commit()` 作为 network 改动**唯一出口**，按判据选择生效方式
  —— 有光口（`pon*/gpon*/xpon*/epon*`，或 UCI 上行设备名匹配）**且角色不是 client**
  → `ubus call network reload`；否则保持 `network restart`
  （子节点要删上行接口、改端口归属，reload 处理不干净）。
  落点 4 处：apply、停用、诊断页「端口并入」按钮（开窗/加入本来就是 reload，不动）。
- **安全网**：reload 后校验 `br-lan` 有地址且 `bat0` 真在 `/sys/class/net/br-lan/brif`，
  不满足自动降级 restart，不会「配置改了但没生效」。
- **回退开关**：`uci set mesh.main.net_restart=1; uci commit mesh` 立刻回到旧行为。
- **OMCI 兜底** `mesh_omci_recover()`：只在「确实被迫走了 restart」时才可能触发，
  且要过三道门槛（有光口 / 该口 carrier 曾 up 过 / 等 15 秒仍未恢复），重启的是
  **airoha-pond 进程**（用户态 OMCI 代理），**不是 pon0 接口**，不会触发驱动重新
  初始化 —— 它是「救 PON」而非「断 PON」。依据：pond 的 procd 只配了 respawn 与
  `file /etc/config/pon`，**没有 watch network.interface**，netifd 重启带不动它。
- **还原不再无条件 reboot**：`mesh_do_revert` 原为 `( sleep 2; sync; reboot )`，
  整机关断重启对光口机型代价太大（SerDes + O1~O5 重来）。改为逐项重载
  （network reload + wifi reload + firewall/dnsmasq）+ 校验管理地址，
  只有确认起不来才兜底 reboot。

---

## r39（2026-10-05）
消灭 LuCI「**迁移配置**」弹窗 —— 后台点开无线页 / 接口页就弹，根源在插件自己写
的是旧格式，不是固件的问题。按之前定的 A 方案（源头改新格式）改 5 个点：

- **根因两条**：
  1. 本工具建无线段一律用 `uci add wireless wifi-iface` → 出来的是**匿名段**
     （`cfg0xxxxx`），LuCI 无线页扫到匿名段就弹「迁移无线配置」；
  2. `network.batmesh` 写的是 `option ifname`（21.02 起已废弃，改为 `device`），
     LuCI 接口页弹「迁移接口配置」。
- **A-1 四处建段全改成具名段**（前缀 `xxmesh_`，避开与固件自带段/用户自建段撞名）：
  `xxmesh_backhaul`（回程）、`xxmesh_ap_<radio>`（AP 镜像，同射频多个自动 `_2/_3`）、
  `xxmesh_pair_ap`（配对 AP）、`xxmesh_pair_sta`（配对 STA，建之前先清同名残留）。
  建段统一走 `mesh_wifi_iface_new()`：名字被占用就自动后退到 `_2/_3`，并打
  `mesh_managed=1` 标记。**收益不止不弹窗**：段名稳定、状态文件丢了也能靠标记把
  自己建的段找回来（以前 LuCI 一点迁移就把段名改掉，脚本从此找不到、删不掉）。
- **A-2 + A-3**：新增 `mesh_net_syntax()` 探测固件语法 ——
  ① `network.loopback.device`（新固件出厂配置一定有）→ `new`；
  ② `/etc/openwrt_release` 主版本号 ≥21 → `new`，≤19 → `old`；
  ③ `/usr/share/hostap/`（24.10 起）→ `new`；④ 都探不出 → `both`（两个都写）。
  `batmesh` 按结果写：21.02+ 只写 `device` 并删掉 `ifname`；19.07 及更早只写
  `ifname`；探测不出就两个都写（netifd 只读自己认识的那个，功能不受影响）。
- **A-4 存量整理不进代码**（没有存量用户，没必要常驻）：需要时跑一次性命令，
  见 README「运维备忘」。
- **A-5**：本文档。

兼容性：具名 `wifi-iface` 段 OpenWrt 全版本（含 19.07）都支持，无代价；
`device` 只在 21.02+ 有效，已由版本探测兜住 —— 2024/2025 的固件（23.05 / 24.10）
零风险，19.07 及更早会自动退回 `ifname`（README 本就要求 21.02+）。

---

## r38（2026-10-05）
修"**其实没在网，却被判定已在网，按键加入被拒**"——真机 .245：退出组网后手动
`meshctl set-role client`，再按加入档，直接被拒，只能绕去网页点加入才成功。

- 根因：`mesh_button_in_network` 只看配置（`enabled=1` + `mesh_id` 非空），
  而 **`mesh_id` 是会残留的**（退出组网没清干净、或上次 join 领到凭证后被停用分支
  打断）。于是"配置看着在网、链路一条都没有"的节点被判成已在网 → 加入档拒绝。
- 修法：新增 `mesh_backhaul_up()` 看**链路实际状态**（mesh 接口有已关联邻居；
  有线回程没有邻居可查，改用"能 ping 通主节点且主节点地址不是自己"判断），
  把 join / open 两个档的拒绝条件从
  `role=X && mesh_button_in_network` 改成再 `&& mesh_backhaul_up`。
  理由本来就写在注释里 —— 拒绝是为了"别打断正在跑的回程"；**回程压根没起来时
  没有任何可打断的通路，就该放行**。
- 另外 `cmd_pair_join` 开头在回程仍通时多打一行风险提示（会切射频 + 重建回程）。

---

## r37（2026-10-05）
修"**凭证领到了、也报已加入，但组网其实是未启用**"——真机 .245 按键组网踩到。

- 现象：主节点"已加入数量 +1"、子节点按键结果显示"已加入网络（按键触发）"，
  但状态页 MESH 状态是**未启用**；主节点 `mesh0` / `batctl` 里根本没有它。
- 根因：`cmd_button_join` 只按 **role** 判断要不要走 `set-role`
  （`if [ "$role" != client ]`），而退出组网 / 自动还原会把 `enabled` 置 0、
  **role 却残留成 client** → 跳过 `set-role` → 而"置 `enabled=1`"正是 `set-role`
  干的活 → 带着 `enabled=0` 去 `pair-join --apply` → `cmd_apply` 开头
  `if [ "$enabled" != "1" ]` 成立，**走停用分支**：刚凭凭证建好的 mesh 接口整个拆掉、
  batman 移除、`status_text` 写成'组网已停用'，然后**照样 return 0**。
  上层看到 rc=0 就报成功 —— "已加入"与"未启用"于是并存。
  （`cmd_button_open` 有对称问题：role 残留 master + enabled=0 时同样跳过 set-role。）
- 修法（三处）：
  1. `cmd_button_join` / `cmd_button_open` 的判断改为
     `[ "$role" != X ] || [ "$(mesh_uci_get main.enabled)" != "1" ]`。
  2. `cmd_pair_join` 入口兜底：未启用就先置 `enabled=1` + `role=client`，
     **按键 / 网页 / 命令行三个入口一起修好**（网页"一键加入网络"不经过 `setRole`，
     同样会踩）。
  3. `cmd_button_join` 在 `--apply` 返回 0 之后复查一次 `enabled`，非 1 就改判失败 ——
     以后再有类似"apply 静默走停用分支"也不会被报成成功。

---

## r36（2026-10-05）
修一个**真实暴露面**：配对 AP 可能长期驻留在子节点上一直广播。

- 现象（真机 .219）：`meshctl pair-status` 显示 `open=0`（窗口已关），但 radio0 上
  就是有个 `phy0-ap1` 在发 `XxMesh-Pair`，`network=lan` —— **密码是固件里公开的
  `xxmesh-pair`，且桥进了内网**：附近任何人连上它就直接进整个 mesh 局域网。
- 根因：删除配对 AP 只认 `mesh_pair=1` 标记 + 状态文件；旧版本建的段**不带标记**，
  状态文件一丢（重启 / 手改 / 跨版本升级）就再也找不到 → 关窗、退出组网都删不掉它。
- 修法：
  1. `mesh_pair_ap_sections()` 双轨认定 —— 标记优先，其次 `mode=ap + 配对 SSID +
     配对密码` 三者同时命中（用户自建的同名 AP 不会有固件里那个固定密码，误删代价
     可接受）；`mesh_pair_ap_del` 改为清除**全部**匹配段而不是只删第一个。
  2. 新增 `mesh_pair_ap_purge()`（删到东西才返回 0，调用方据此决定要不要 reload），
     在三处兜底：`cmd_apply`（窗口关闭时，且放在 wifi reload 之前）、`set-role` 切成
     子节点时、守护进程启动时（并立即 reload 撤广播）。

---

## r35（2026-10-05）
让**恢复出厂的设备（内网 192.168.1.1）也能真正开箱一键组网** —— 不用先手动改 IP：

- 撞号在网络层无解，但可以**换个地址敲门**：主节点开窗期间在 LAN 桥上临时挂一个
  `/32` 别名 `192.0.2.1`（RFC 5737 TEST-NET-1，真实网络里不存在，不会被内核特殊处理），
  关窗立刻摘掉（`mesh_pair_alias_up/down`）。
- 待入网节点检测到撞号后，把候选地址换成这个备用地址：它不是本机地址 → 不会被本地
  投递；再叠加 r33 的绑设备发送 + 主机路由，报文就能从配对网卡正常出去。
- 只在检测到撞号时才走这条路，正常场景零额外开销；主节点版本较旧（没挂备用地址）
  时仍会超时，但超时提示会说明原因。
  ⚠ 备用地址见 r45 —— r35 选的 `192.0.2.1` 会撞上 uhttpd 的 rfc1918_filter，已换掉。

---

## r34（2026-10-05）
**待入网节点的内网地址不能和主节点同号**（出厂路由器默认 `192.168.1.1`，一撞一个准）：

- 该地址一旦是本机自己拥有的，发往它的报文被内核**本地投递**（local 路由表优先于
  main 表，连 SO_BINDTODEVICE 都压不过），curl 实际打到了自己的 uhttpd 拿回
  `not_master`，然后干等 300 秒超时 —— 主节点那边一点痕迹都没有，极难排查。
- 这事没法从网络层救（你没法"访问"一个你自己拥有的地址），只能改本机内网。
  所以 `[3/4]` 先把候选地址里与本机地址相同的剔掉，**全被剔光就立刻报错**并给出
  指引（改成同网段其它地址，如 `192.168.1.219`），不再让用户白等 5 分钟。
  ⚠ 同网段本身没问题（r33 已解决），撞的是"同号"不是"同段"。

---

## r33（2026-10-05）
配对取凭证的**真正修法**（r32 的"钉主机路由"方案真机复测无效，本版才修好）：

- **r32 方案为什么不行**：设备名 `pairsta0` 是 wifi-iface 里的 `ifname`，只是**请求**，
  实际叫什么由 wifi-scripts 决定；名字对不上时 `ip route replace` 报
  "Cannot find device" 又被 `2>/dev/null` 吞掉，等于什么都没做。
- **修法（4 条）**：
  1. 出口设备运行时解析：netifd `device` → `l3_device` → `ip -o link` 扫 `*staN`
     → 旧常量兜底，并打印"配对网卡"一行；
  2. `curl --interface <设备名>`（SO_BINDTODEVICE）—— 把路由查找也限制在这张网卡上，
     不再依赖主机路由；
  3. 配对期间临时关 `rp_filter`（回包从 STA 进来、反向路径算到 br-lan 会被丢），
     cleanup 按原值还原；
  4. 绑设备名拿不到响应时退回绑源地址（老写法），双保险。

---

## r32（2026-10-05）
修"配对信号连上了、地址也拿到了，却永远领不到凭证"（真机 .219，耗满 300 秒超时）：

- **同网段路由陷阱**：待入网的节点自己是个独立路由器（内网 `192.168.1.219/24`），
  配对 STA 又从主节点拿到 `192.168.1.132/24` —— **同一个子网出现在两个接口上**，
  内核有两条同前缀直连路由，去 `192.168.1.1` 的报文挑了先起来的 br-lan，
  而 br-lan 那一侧根本没有通往主节点的链路。`curl --interface` 只 bind 源地址、
  **不改出口设备**，所以主节点一个包都收不到，页面表现就是一直在"等待主节点开放加入"。
- **修法（不够，见 r33）**：给每个候选主节点地址钉一条走 STA 的 `/32` 主机路由
  （`ip route replace <master> dev <sta> src <ip>`）。真机复测**仍然失败** ——
  真正修好是 r33。

---

## r31（2026-10-05）
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

---

## r30（2026-10-05）
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

---

## r29（2026-10-05）
修两个长期误报的显示问题。

**①「端口内网化」恒为 false（主子节点都报"部分端口未并入"）**
- 根因：这几台机器**根本没有 `wan*` 端口**（上行是 `pon0` 光口），而枚举函数写的是
  `ls -d /sys/class/net/lan* /sys/class/net/wan*` —— `wan*` 不匹配时**整条命令返回非 0**，
  于是掉进 `eth*` 兜底分支，把 DSA 的 conduit **`eth0`** 当成物理口。期望成员变成
  `eth0 bat0`，而 eth0 不可能出现在 br-lan 的成员里，判定自然永远失败。
- 改法：`lan*` 与 `wan*` **分开判断，任一存在即按 DSA 处理**；`eth*` 只在两者都不存在时兜底。
- 语义修正（主节点）：主节点本来就要保留上行口，不该拿"全端口内网化"这把尺子量它。
  现在主节点**只校验 bat0 是否真的在 br-lan 里**，文案改为
  「主节点：bat0 已并入 br-lan（上行口按要求保留，全端口内网化不适用）」。
  子节点维持全量校验（全部物理口 + bat0）。

**② 节点列表里的"幽灵行"（掉线的子节点一直挂在那里）**
- 根因：注册表只在**有子节点上报**时才顺带清理一次，且阈值硬编码 **24 小时**。
  于是"最后一台子节点掉线后再无上报"时，那条记录会一直以 offline 常驻一整天。
- 改法：
  - 新增 `mesh_registry_ttl()`（`mesh.main.peer_ttl`，默认 **3600** 秒，下限 60），
    替换原来的硬编码 86400；下限取 60 是为了不把"正在重启/升级"的节点删掉重排号
    （节点序号按首次注册时间排，决定信道错开）。
  - 新增 `mesh_registry_prune()`，并在 **`meshctl status` 里主动调一次** ——
    status 是界面每 10 秒都会走的路径，这样即使全网再无上报也能自愈。
  - peers JSON 增加 `lastseen`（epoch），离线行在界面上显示「最后上报 X 前」，
    据此分辨"刚重启"和"早就不在了"。
  - 设置页「链路控制」新增「离线节点保留时长(秒)」。

**顺带**：`mesh_brlan_members_report` 现在会打印判定口径、上行口排除清单与缺失项，
排障时能一眼看出到底按什么规则算的。

---

## r28（2026-10-05）
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

---

## r27（2026-10-05）
文案与默认值统一，不含功能改动。

- 角色标签「主节点(接光猫 · 配置源)」→「**主节点(上网网关 · 配置源)**」（设置页下拉、状态页角色卡片，以及两处说明文字）。主节点的上行不一定是光猫（光猫桥接 / 上级路由 / 旁路等情况同样成立），写"上网网关"才准确。
- 「已连接邻居」→「**已连接节点**」；状态页最下面的大框标题「邻居节点」→「**节点列表**」，框内表格第一列的列头「邻居节点」→「**节点**」。空表提示同步改为「暂无已连接的节点」。
- 配对信号默认值改为 **`XxMesh-Pair` / `xxmesh-pair`**（原 `PonWrt-Pair` / `ponwrt-pair`），与 Mesh ID 的 `XxMesh-` 前缀一致：`functions.sh` 的两个 DEFAULT 常量、`/etc/config/mesh` 的出厂值、设置页两个 placeholder、状态页配对卡片的兜底显示全部同步。
  ⚠ 已经配过的机器不受影响（UCI 里已有值就用已有值），只有恢复出厂或 `uci set mesh.main.pair_ssid=...` 才会拿到新默认；若全网已有节点用的是旧值，请手动统一。

---

## r26（2026-10-05）
把一键加入做成网页按钮（第三步）：rpcd 放行 `pair_*` 并后台化，组网状态页加配对卡片、组网设置页加配对设置区。

- **三个配对动作必须后台执行并立即返回**：`pair-open` / `pair-close` 会触发 `wifi reload`（十几秒），`pair-join` 最坏要等满 5 分钟并紧接着跑一次 `apply`（子节点会改 IP + 重启网络）。同步等只会让 rpcd 连接超时、前端看到"网络错误"。真实结果写进 `/tmp/mesh/pair-last`（tmpfs，重启即消失），进度行写 `/tmp/mesh/pair.log`。
- **进度可见**：`meshctl status` 新增 `pair` 块（窗口状态 / 剩余秒数 / 已加入台数 / 后台任务 busy / 上次结果 / 最新进度行），状态页 10 秒一轮的轮询顺带刷新，不用额外加定时器。
- **网页上开窗可改时长**（默认 10 分钟，可选 2/5/10/30 分钟或常开），开窗期间显示倒计时、配对 SSID/密码、已加入台数，可随时「立即关闭」。
- 仓库归属整理：`origin` 指向 `https://github.com/xxosdev/luci-app-mesh.git`，维护者改为 `Xx`，移除原作者的赞助收款码。

---

## r25（2026-10-05）
后端打通「一键加入」：新增 `action=join` 端点与 `meshctl pair-open / pair-close / pair-status / pair-join`（真机端到端验收通过）。

- **免鉴权端点必须放在 token 校验之前**：`mesh-sync` 的 token 就是回程密码，出厂节点连那道门都敲不开——"先有凭证还是先有连接"这个死循环只能靠一条免鉴权通道解开。安全性只依赖「只有已启用组网的主节点响应」+「只在窗口期响应」。
- **窗口到期改由守护进程收摊**：早期版本用一次性 `sleep` 后台进程看门狗，连续开窗时残留的旧进程会把新窗口误关。现在窗口是一个 expire 时间戳，守护进程每 10 秒核对（实测 240 秒窗口准时自动关闭）。
- **配对 STA 必须先对齐信道**：同一 phy 上所有接口共享**一个**信道，STA 没法独自跳频——真机实测子节点射频在 ch11、配对 AP 在 ch1 时永远关联不上。所以起 STA 前先用 `mesh_pair_scan_channel` 扫出配对信号所在信道并临时切过去，用完还原。
- **踩坑记录**：`jsonfilter` 表达式里带连字符的键必须写成 `@['ipv4-address'][0]['address']`，写成 `@.ipv4-address[0].address` 会报 `Invalid escape sequence` 且**静默返回空**（表现为"接口明明 up 了，脚本却以为没拿到地址"）。

---

## r24（2026-10-05）
回程凭证自动生成 + 修好设置页密码工具按钮：

- **Mesh ID 按本机 MAC 派生**：主节点首次应用且 `mesh_id` 为空时，派生为 `XxMesh-<MAC 后 6 位>` 并写回 UCI。全网同固件不再都叫同一个名字——同信道上邻居的同款设备会反复尝试 SAE 握手（空口干扰 + 刷日志）。取 MAC 时特意避开 `bat0`（它是 batman-adv 的软接口，MAC 由 batman 自己生成），只从 `eth*`/`br-lan` 取。
- **回程密码自动生成**：同样只在为空时生成 16 位 `[A-Za-z0-9]` 随机串（不含 `+/=` 等 URL 保留字符——它要拼进同步请求的查询串）。判定只看"是否为空"，用户手工填的弱密码不会被悄悄改掉。
- **出厂配置必须留空**：`/etc/config/mesh` 里 `mesh_id` / `mesh_key` 改成空串。原来写死 `OpenWrtMesh`，新刷机永远走不到派生逻辑。
- **修好密码工具按钮点了没反应**：LuCI 的密码框是**两层结构**——`getElementById('cbid.mesh.main.mesh_key')` 拿到的是外层 `div`，真正的 `input` 的 id 是 `widget.cbid.mesh.main.mesh_key`；且 `<button>` 在 form 里默认 `type=submit`，不写就会触发保存。现在按 `widget.` → 容器内 `input` → `input.cbi-input-password` 三级查找，并全部显式 `type=button`。

---

## r23（2026-10-03）
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

## r22（2026-10-02）
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

---

## r21（2026-09-28）
修复组网设置「回程频段 / 回程信道」不联动、且频段不按实际硬件列出的问题：
- **回程频段按硬件列出**：`meshctl status` 新增 `channels` 字段（各射频用 `iw phy info` 取真实信道号，含 DFS）；前端据此只显示本机实际拥有的频段（没有的频段不出现），默认频段也按硬件择优。
- **回程信道随频段联动**：原来信道下拉把 5G/2.4G 信道静态混在一个列表里、与频段选择毫无关联。现拆成 `channel_5g/2g/6g/auto` 四个选项，各自 `depends('band', …)` —— 选 5G 只列 5G 信道、选 2.4G 只列 2.4G 信道，LuCI 在切换频段时自动显隐并重渲染；四个选项映射到同一 UCI 项 `channel`，隐藏时不删值。

---

## r20（2026-09-24）
基于 r19 全量代码审查，修复三处逻辑缺陷（不改变既有正常组网行为，仅修正边界一致性）：
- **漫游自检 `fast_skip` 纳入脚本自身指纹**：`97-wifi-roaming` / `99-dawn-roaming` 的快速通道原本只比对配置文件的 md5，改了脚本强制规则后已部署设备永不重跑、旧规则滞留。现把脚本本体 `$0`（解析 rc.d 软链接后的真实路径）的 md5 并入指纹，脚本升级 / 调参后必然重新执行。
- **AP 镜像尊重主节点 `disabled` 状态**：`mesh-sync` 下发 AP 时新增 `disabled` 字段，子节点按主节点意图镜像（主节点有意关闭的 AP，子节点不再强制开启）。`mesh_wifi_ensure_aps_up` 已对 `disabled=1` 的 AP 跳过，不会把镜像结果又顶回去。
- **配置镜像循环不再因空 SSID 提前退出**：`meshctl` 载入主节点 AP 列表时，改以「band 下标是否真实存在」为哨兵，空 SSID（合法隐藏网络）不再导致后续 AP 漏镜像。
