'use strict';
'require view';
'require rpc';
'require ui';

/* ============================================================================
 * 连接设备 —— 查看本机各 AP 上关联的无线客户端，并支持踢除 / 引导 / 测量
 *
 * 定位：本插件一直只有「组网/无线配置」这类**组态**能力，没有任何**运行时**
 * 的客户端管理。本页补上这一块，底层**只用到固件自带的 hostapd ubus 接口**，
 * 不引入任何第三方包（dawn / usteer / nrsyncd 都不需要）：
 *   hostapd.<bss> get_clients            关联客户端（信号/速率/字节/airtime/能力位）
 *   hostapd.<bss> list_bans              停用名单
 *   hostapd.<bss> del_client             踢下线 / 停用 / 解除停用
 *   hostapd.<bss> bss_transition_request  802.11v 软踢（引导换 AP，不断流）
 *   hostapd.<bss> rrm_beacon_req         让设备回报周围 AP 的实测信号
 *   luci-rpc getDHCPLeases               设备名称 / IP
 *
 * ★ 为什么只做**本机**的客户端：踢人/引导的 ubus 调用必须落到「客户端当前所在的
 *   那个 BSS」上，而 BSS 是各节点本地的 hostapd 实例。跨节点操作需要在 mesh-sync
 *   里另开一条指令通道（工作量与风险都更大），本期不做 —— 见下方 note。
 *
 * ★ 防版本漂移（这是本页的核心设计约束）：
 *   1. 能力探测：后端用 `ubus -v list` 在**运行时**探测方法是否存在，结果进
 *      capabilities。前端**按能力渲染按钮** —— 缺 del_client 就没有「踢下线」，
 *      缺 bss_transition_request 就没有「引导」。绝不假设接口一定在。
 *   2. 逐字段降级：客户端对象的每个字段（signal / rate / bytes / airtime …）都
 *      「有则显示、无则省略」，不留空白占位、不显示 undefined。
 *   3. 完全没有 hostapd 对象时 → 整页降级成一行说明，不报错、不白屏。
 *   以上三点保证：无论固件怎么升级、hostapd 怎么改名，功能只会「少一块」，
 *   不会「整页坏掉」。
 * ========================================================================== */

var callMeshStatus = rpc.declare({ object: 'mesh', method: 'status', expect: {} });
/* ★ expect 必须是 {} —— 它会取返回对象的第一个键并解包（见 tools.js 的注释）。
   写 {stdout:''} 会把整个对象解成 stdout 字符串，调用方拿 res.code 就永远是 undefined。 */
var callMeshExecArg = rpc.declare({ object: 'mesh', method: 'exec', params: [ 'cmd', 'arg' ], expect: {} });

/* ★ 客户端数据的正确来源是 `meshctl clients`（走 exec），**不是** `mesh status`：
   status 返回的是组网状态（enabled/role/peer…），里面根本没有 bss/clients 字段。
   本页早期版本误用 status 取列表 → 永远拿到空 bss → 页面显示"未找到无线接口"。
   exec clients 的 stdout 是一整段 JSON 字符串，需要 JSON.parse 一次。 */
function fetchClients() {
	return callMeshExecArg('clients', '').then(function (res) {
		var txt = (res && typeof res === 'object') ? (res.stdout || '') : String(res || '');
		var code = (res && typeof res === 'object') ? Number(res.code) : 0;
		if (code !== 0) throw new Error(txt || _('读取失败'));
		try {
			return JSON.parse(txt);
		} catch (e) {
			throw new Error(_('返回数据解析失败：%s').format(txt.slice(0, 120)));
		}
	});
}

/* 停用时长档位（秒）。0 = 只踢不封禁（踢掉后设备可立刻重连）。
   末档用 1 年近似「直到重启」—— hostapd 的 ban 只存在内存里，重启/无线重载即清空，
   所以不存在"永久拉黑"，给个足够大的值即可覆盖正常使用周期。 */
var BAN_OPTS = [
	{ v: '0',      t: '只踢下线（可立即重连）' },
	{ v: '60',     t: '停用 1 分钟' },
	{ v: '300',    t: '停用 5 分钟' },
	{ v: '1800',   t: '停用 30 分钟' },
	{ v: '3600',   t: '停用 60 分钟' },
	{ v: '31536000', t: '停用直到重启' }
];

function ensureCss() {
	if (document.getElementById('mesh-css')) return;
	var href = (window.L && L.resource) ? L.resource('view/mesh/mesh.css')
		: '/luci-static/resources/view/mesh/mesh.css';
	document.head.appendChild(E('link', { id: 'mesh-css', rel: 'stylesheet', href: href }));
}

function section(title, children) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, title),
		E('div', { 'class': 'cbi-section-node' }, children)
	]);
}

function note(text, kind) {
	return E('div', { 'class': 'mesh-note' + (kind ? ' ' + kind : '') }, text);
}

function bandText(b) {
	return b === '2g' ? '2.4 GHz' : (b === '6g' ? '6 GHz' : (b === '5g' ? '5 GHz' : (b || '—')));
}

/* 频段频率 → 短标签（信号弹窗里用，按信号值本身排序，不按频段分组）。 */
function bandShort(freq) {
	var f = Number(freq);
	if (!isFinite(f) || f <= 0) return '';
	if (f < 2500) return '2.4 GHz';
	if (f < 5900) return '5 GHz';
	return '6 GHz';
}

/* ---------- 数值格式化（全部容错：拿不到就返回 null，调用方跳过该项） ---------- */

/* bps -> 人话。hostapd 的 rate 单位是 bit/s（不是 byte/s） */
/* 协商速率：后端已换算成 Mbps（iwinfo 原始单位是 kbit/s，/1000 得 Mbps）。
   ★ 统一用 Mbps 单位（哪怕上千也显示成 2160 Mbps），不让用户去换算 Gbps。 */
function fmtNego(mbps) {
	var n = Number(mbps);
	if (!isFinite(n) || n <= 0) return null;
	return Math.round(n) + ' Mbps';
}

/* 时长：秒 → 人话（已连接时长 / 空口占用时长都用它）。 */
function fmtDuration(sec) {
	var n = Number(sec);
	if (!isFinite(n) || n < 0) return null;
	var d = Math.floor(n / 86400);
	var h = Math.floor((n % 86400) / 3600);
	var m = Math.floor((n % 3600) / 60);
	var s = Math.floor(n % 60);
	if (d > 0) return d + ' 天 ' + h + ' 小时';
	if (h > 0) return h + ' 小时 ' + m + ' 分';
	if (m > 0) return m + ' 分 ' + s + ' 秒';
	return s + ' 秒';
}

/* ★★ 方向约定（本页最容易搞错的地方，改任何速率相关代码前先读这段）：
   hostapd 的 bytes.{rx,tx} 与 iwinfo 的 rx/tx **都是 AP 视角**：
       rx = 设备发给 AP   → 站在设备上看是「上传 ↑」
       tx = AP 发给设备   → 站在设备上看是「下载 ↓」
   界面是给**用设备的人**看的，所以：↓ 一律取 tx、↑ 一律取 rx。
   早期版本按字段名直出（↓rx ↑tx），用户拿手机测速一对比就发现上下行是反的。 */

/* 实时速度：后端给的是**累计**字节，这里按同一 MAC 前后两帧做差算速度（bps）。
   ★ 每个 MAC 各自记一份 {rx,tx,t}，比用全局时钟准（设备可能中途才出现）。
   ★ 首帧/间隔异常时返回 null —— 但**界面仍然显示这一项，只是数值为 0**：
     整项时有时无会让列表忽长忽短、也让用户分不清"真的很闲"和"没测到"。 */
var _prev = {};
/* 协商速率峰值表：mac -> { t: 峰值 Mbps, mhz, nss, mcs, he }。每个 MAC 各记一份。 */
var _peak = {};

function snapSpeed(c) {
	if (!c || !c.mac) return null;
	var cur = {
		rx: Number(c.bytes_rx) || 0,
		tx: Number(c.bytes_tx) || 0,
		t: Date.now()
	};
	var prev = _prev[c.mac];
	_prev[c.mac] = cur;
	if (!prev) return null;
	var dt = (cur.t - prev.t) / 1000;
	if (!(dt > 0.5) || dt > 600) return null;   // 间隔异常（切后台/手动连点刷新）→ 放弃这轮
	var drx = cur.rx - prev.rx, dtx = cur.tx - prev.tx;
	if (drx < 0 || dtx < 0) return null;        // 计数回绕或重新关联 → 丢弃
	return { rx: (drx * 8) / dt, tx: (dtx * 8) / dt };
}

function fmtSpeed(bps) {
	var n = Number(bps);
	if (!isFinite(n) || n < 0) return '0 bps';
	if (n >= 1e6) return (n / 1e6).toFixed(1) + ' Mbps';
	if (n >= 1e3) return Math.round(n / 1e3) + ' Kbps';
	return Math.round(n) + ' bps';
}

function fmtBytes(b) {
	var n = Number(b);
	if (!isFinite(n) || n < 0) return null;
	var u = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n : n.toFixed(1)) + ' ' + u[i];
}

/* 信号：只显示**原始 dBm**，不做"优秀/一般"分级 —— 分级阈值是拍脑袋定的，
   同一台设备换个位置就从"良好"跳"优秀"，反而让人怀疑数据；原始值自己会说话。 */
function sigText(dbm) {
	var n = Number(dbm);
	if (!isFinite(n)) return null;
	return n + ' dBm';
}

/* ---------- 小动作调用封装 ---------- */

/* 成功返回 {ok:true,text}；失败返回 {ok:false,err} —— 与 tools.js 同款，
   刻意不把失败静默成空串（否则界面分不清"没反应"和"失败"）。 */
function runClientCmd(cmd, arg) {
	return callMeshExecArg(cmd, arg).then(function (res) {
		var txt = (res && typeof res === 'object') ? (res.stdout || '') : String(res || '');
		var code = (res && typeof res === 'object') ? res.code : 0;
		return { ok: Number(code) === 0, text: txt, code: code };
	}, function (e) {
		return { ok: false, err: String((e && e.message) ? e.message : e) };
	});
}

function toast(ok, text) {
	ui.addNotification(null, E('p', {}, text), ok ? 'success' : 'danger');
}

/* ========================================================================== */

return view.extend({
	load: function () {
		/* status 只用来判断"这个节点是否在组网里"（决定是否显示顶部说明）；
		   clients 才是列表本体。两者都失败也不抛 —— 交给 renderInto 逐级降级。 */
		return Promise.all([
			callMeshStatus().catch(function () { return {}; }),
			fetchClients().catch(function (e) { return { __error: String(e && e.message || e) }; })
		]).then(function (r) {
			return { status: r[0] || {}, clients: r[1] || {} };
		});
	},

	render: function (payload) {
		ensureCss();
		payload = payload || {};
		var status = payload.status || {};
		var meshOn = (Number(status.enabled) === 1);

		var self = this;
		var host = E('div', {});

		/* 重新拉一次并重绘整个列表（操作后调用）。刻意做成"全量重取"而不是局部改行：
		   踢人/封禁是异步生效的（设备要几百毫秒才真掉线），全量刷新能拿到最真实的
		   当前状态，也避免前端状态与 hostapd 实际状态不一致。 */
		function refresh(silent) {
			return fetchClients().then(function (st) {
				renderInto(st || {}, silent);
			}, function (e) {
				if (!silent) toast(false, _('读取失败：%s').format(e));
			});
		}

		function renderInto(st, silent) {
			st = st || {};
			var cap = st.capabilities || {};
			var bss = Array.isArray(st.bss) ? st.bss : [];

			while (host.firstChild) host.removeChild(host.firstChild);

			/* ---- 顶部说明 ---- */
			if (meshOn) {
				host.appendChild(note(_(
					'列表上半是连在**本机**的设备（可踢除 / 引导 / 测量），下半是连在' +
					'**其他节点**的设备 —— 后者本机管不到，点「去该节点管理」跳转过去操作。' +
					'「协商」是该设备连入以来达到过的**峰值**速率（反映链路能力，不会因设备空闲而掉低），' +
					'「实时」是当前实际收发速度（每 15 秒刷新；页面刚打开时还没有对比值，显示为 0）。' +
					'↓ 是**下载**（AP→设备），↑ 是**上传**（设备→AP）。')));
			}

			/* ---- 取数失败（exec 报错 / JSON 解析失败）→ 明确提示，不白屏 ---- */
			if (st.__error) {
				host.appendChild(note(_('读取连接设备失败：%s').format(st.__error), 'orange'));
				return;
			}

			/* ---- 能力探测结果 ---- */
			var canKick  = !!cap.del_client;
			var canSteer = !!cap.bss_transition_request;
			var canProbe = !!cap.rrm_beacon_req;
			var canList  = !!cap.get_clients;

			if (!cap.bss_ok || !canList) {
				host.appendChild(note(_(
					'本固件未提供无线客户端查询接口（hostapd ubus 不可用），无法显示连接设备。' +
					'这不影响组网本身。'), 'orange'));
				return;
			}
			if (!canKick && !canSteer) {
				host.appendChild(note(_(
					'本固件的 hostapd 未提供客户端管理接口，仅能查看列表，无法踢除或引导。'), 'orange'));
			}

			/* ---- 单一列表：不按频段分组 ----
			   频段改在每台设备上标一个小标签（2.4G / 5G）。这样用户想按信号排序、
			   想一眼扫完全部设备都更容易；按频段分组会把同一台设备的手机和笔记本
			   拆到两个 section 里，找起来反而绕。 */
			var all = [];
			bss.forEach(function (b) {
				(Array.isArray(b.clients) ? b.clients : []).forEach(function (c) {
					all.push({ c: c, band: b.band, iface: b.iface, ssid: b.ssid });
				});
			});
			var remote = Array.isArray(st.remote) ? st.remote : [];

			if (!all.length && !remote.length) {
				host.appendChild(note(_('当前没有设备连接。'), 'orange'));
				return;
			}

			var body = [];
			/* 本机设备在前（可操作），远端设备在后（只能跳转） */
			all.forEach(function (it) { body.push(clientCard(it.c, it, cap, false)); });
			remote.forEach(function (c) { body.push(clientCard(c, null, cap, true)); });

			host.appendChild(section(
				E('span', {}, [
					_('连接设备'),
					E('span', { 'class': 'mesh-pill grey', style: 'margin-left:8px' },
						_('本机 %s 台').format(all.length) +
						(remote.length ? _(' · 其他节点 %s 台').format(remote.length) : ''))
				]),
				body
			));
		}

		/* ---- 单个设备卡片 ----
		   it  = { c, band, iface, ssid }（本机设备）；远端设备传 null，isRemote=true */
	function clientCard(c, it, cap, isRemote) {
		var canKick  = !!cap.del_client;
		var canSteer = !!cap.bss_transition_request;
		var canProbe = !!cap.rrm_beacon_req;
		var canMap   = !!cap.dawn;
		var band = it ? it.band : null;

			/* 第一行：设备名（拿不到就退成 MAC）+ 频段 + 在线/停用标记 */
			var nameText = (c.hostname && String(c.hostname).trim()) ? c.hostname : _('（未知设备）');
			var tags = [];
			/* ★ 频段就标在这里（不再按它分组） */
			if (band) tags.push(E('span', { 'class': 'mesh-pill grey', style: 'margin-left:8px' }, band));
			if (isRemote) {
				tags.push(E('span', { 'class': 'mesh-pill grey', style: 'margin-left:6px' },
					c.node_ip ? _('连在 %s').format(c.node_ip) : _('连在其他节点')));
			}
			if (c.banned) tags.push(E('span', { 'class': 'mesh-pill grey', style: 'margin-left:6px' }, _('已停用')));
			if (!isRemote && c.online === true) tags.push(E('span', { 'class': 'mesh-pill ok', style: 'margin-left:6px' }, _('在线')));

		/* ★★ 必须把 tags **摊平**成一层再传：E() 不会递归展开嵌套数组，
		   直接传 [text, [span,span]] 时子数组被 createTextNode 字符串化，
		   页面上就变成 "Xiaomi-15-Pro[object HTMLSpanElement],[object HTMLSpanElement]"。
		   实测踩过，别改回嵌套写法。 */
		var line1 = E('div', { style: 'font-size:14px;font-weight:600;color:#333' },
			[ nameText ].concat(tags));

			/* 第二行：MAC（+ IP，若有） */
			var ids = [ E('span', { 'class': 'mesh-tag' }, c.mac || '?') ];
			if (c.ip) ids.push(E('span', { 'class': 'mesh-tag', style: 'margin-left:10px' }, c.ip));
			var line2 = E('div', { style: 'margin:2px 0' }, ids);

			/* 第三行：信号 / 协商速率 / 实时速度 / 流量 —— 逐项"有则显示" */
			var metrics = [];
			var st = sigText(c.signal);
			if (st) metrics.push(_('信号') + ' ' + st);

			/* 协商速率（iwinfo）。
			   ★★ 为什么用**峰值**而不是瞬时值（实测踩过，别改回去）：
			     实测 iwinfo 的 rx/tx.rate 是"最近一帧用的档位"，会在 17 Mbps 与
			     2401 Mbps 之间反复跳，连带宽 mhz 都会跟着跳成 20MHz；而内核的
			     thr（期望吞吐）在多设备/接收型场景下也并不可靠（一台上传为主的手机
			     thr 只有 5 Mbps，但下行瞬时能到 1 Gbps 以上）。把这种值当"协商速率"
			     显示，用户会以为自己的 WiFi 只有 5 Mbps。
			   ★ 真正稳定的是**带宽/流数/HE 这些协商参数**（连上后不变）。所以：
			     - 速率数字用「连入以来达到过的**峰值**」（max(rx,tx) 的 Mbps），
			       反映链路能力，不会因设备锁屏/空闲就掉低；
			     - 括号里的带宽/流数/MCS 取达到峰值那一轮的值（同样稳定）。
			   ★ 每个 MAC 各自记一份峰值到 _peak，比用全局时钟准。
			   ★ 本机设备**恒显示**（测不到就 0）；远端设备不显示（本机没有它的 assoclist）。 */
			if (!isRemote && (cap.iwinfo || c.nrx != null || c.ntx != null)) {
				var curT = Math.max(Number(c.nrx) || 0, Number(c.ntx) || 0);
				var pk = _peak[c.mac];
				if (!pk || curT >= pk.t) {
					_peak[c.mac] = { t: curT, mhz: c.nmhz, nss: c.nnss, mcs: c.nmcs, he: c.nhe };
					pk = _peak[c.mac];
				}
				var detail = [];
				if (pk.mhz) detail.push(pk.mhz + 'MHz');
				if (pk.nss) detail.push(pk.nss + '×' + pk.nss);
				if (pk.mcs != null && pk.mcs !== '') detail.push((pk.he ? 'HE-MCS ' : 'MCS ') + pk.mcs);
				metrics.push(_('协商') + ' ↓' + (fmtNego(pk.t) || '0 Mbps')
					+ (detail.length ? '（' + detail.join(' · ') + '）' : ''));
			}

			/* 实时速度：bytes 前后两帧做差。首帧没对比值 → 显示 0（不隐藏整项）。
			   ★ 只对**本机**设备显示：远端设备的 bytes 本机拿不到，硬算只会得到假的 0。 */
			if (!isRemote) {
				var sp = snapSpeed(c);
				metrics.push(_('实时') + ' ↓' + fmtSpeed(sp ? sp.tx : 0)
					+ ' ↑' + fmtSpeed(sp ? sp.rx : 0));
			}

			/* 累计流量：同样按设备视角 —— 下载=AP 的 tx，上传=AP 的 rx */
			var bdown = fmtBytes(c.bytes_tx), bup = fmtBytes(c.bytes_rx);
			if (bdown || bup) metrics.push(_('累计流量') + ' ↓' + (bdown || '0 B') + ' ↑' + (bup || '0 B'));
			/* ★★ 已连接时长（用户要看的是这个，不是空口占用）：
			   airtime 是"这台设备累计占用了多少空口时间"，跟"连了多久"是两回事，
			   而且空闲设备 airtime 很小（实测只 54 秒却连了好几天）—— 直接显示会被误认为
			   "经常掉线"。真正想表达的是"已连接 X 天/小时"。
			   字段改用 iwinfo 的 connected_time（秒），由后端取 nconn。 */
			var ct = (c.nconn != null) ? fmtDuration(Number(c.nconn)) : null;
			if (ct) metrics.push(_('已连接') + ' ' + ct);
			if (c.kv_capable) metrics.push(_('支持 802.11k/v'));

			/* 远端设备拿不到信号/速率/流量，别留一行空的 —— 说清为什么没有。 */
			if (isRemote && !metrics.length) {
				metrics.push(_('该设备连在别的节点上，本机读不到它的信号与速率'));
			}

			var line3 = metrics.length
				? E('div', { 'class': 'mesh-muted' }, metrics.join('　·　')) : null;

			/* 第四行：动作按钮 —— 按能力渲染，能力缺失就不出现（不是置灰，是根本不显示） */
			var btns = [];

			/* ★ 连在别的节点上的设备：本机 hostapd 管不到它（BSS 是那台节点的），
			   硬给按钮点了只会报"未找到该设备"。所以不给操作按钮，改成跳转过去。 */
			if (isRemote) {
				if (c.node_ip) {
					btns.push(E('a', {
						'class': 'btn cbi-button',
						href: 'http://' + c.node_ip + '/cgi-bin/luci/admin/network/mesh/clients',
						target: '_blank', rel: 'noopener'
					}, _('去该节点管理')));
				} else {
					/* 多台子节点时定位不到具体哪台 → 不猜，只说明 */
					btns.push(E('span', { 'class': 'mesh-muted' },
						_('请登录该设备所在节点进行管理。')));
				}
				var line4r = btns.length ? E('div', { 'class': 'mesh-btnrow' }, btns) : null;
				return E('div', {
					'class': 'mesh-card',
					style: 'margin-bottom:10px'
				}, [ line1, line2, line3, line4r ].filter(Boolean));
			}

			if (canKick) {
				btns.push(E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					click: function (ev) {
						ev.preventDefault();
						askKick(c, it);
					}
				}, _('踢下线')));
			}

			if (canSteer) {
				btns.push(E('button', {
					'class': 'btn cbi-button',
					click: function (ev) {
						ev.preventDefault();
						ev.target.disabled = true;
						runClientCmd('client_steer', c.mac).then(function (r) {
							ev.target.disabled = false;
							toast(r.ok, r.ok ? (r.text || _('已发送引导请求')) : (r.text || r.err || _('引导失败')));
						});
					}
				}, _('引导到更优节点')));
			}

		/* 信号测量 / 各节点信号（能力自适应）：
		   ★ dawn 可用 →「查看各节点信号」：直接弹窗显示该设备在每个节点/频段上的
		     实测信号（dawn 每 15 秒自动汇总一次，数据现成、不用等）。
		   ★ 无 dawn 但有 11k →「测量周围信号」：发一次性测量，结果落在系统日志
		     （多数手机只回空报告，故仅作兜底）。
		   两者不会同时出现。 */
		if (canMap) {
			btns.push(E('button', {
				'class': 'btn cbi-button',
				click: function (ev) {
					ev.preventDefault();
					showSignalMap(c);
				}
			}, _('查看各节点信号')));
		} else if (canProbe) {
			btns.push(E('button', {
				'class': 'btn cbi-button',
				click: function (ev) {
					ev.preventDefault();
					ev.target.disabled = true;
					runClientCmd('client_probe', c.mac).then(function (r) {
						ev.target.disabled = false;
						toast(r.ok, r.ok ? (r.text || _('已请求测量')) : (r.text || r.err || _('测量请求失败')));
					});
				}
			}, _('测量周围信号')));
		}

			if (c.banned && canKick) {
				btns.push(E('button', {
					'class': 'btn cbi-button cbi-button-action',
					click: function (ev) {
						ev.preventDefault();
						ev.target.disabled = true;
						runClientCmd('client_unban', c.mac).then(function (r) {
							toast(r.ok, r.ok ? (r.text || _('已解除停用')) : (r.text || r.err || _('解除失败')));
							refresh(true);
						});
					}
				}, _('解除停用')));
			}

			var line4 = btns.length ? E('div', { 'class': 'mesh-btnrow' }, btns) : null;

			return E('div', {
				'class': 'mesh-card',
				style: 'margin-bottom:10px' + (c.banned ? ';opacity:.72' : '')
			}, [ line1, line2, line3, line4 ].filter(Boolean));
		}

		/* ---- 踢人（含停用时长选择）---- */
		function askKick(c, it) {
			var sel = E('select', { 'class': 'cbi-input-select' },
				BAN_OPTS.map(function (o) {
					return E('option', { value: o.v }, _(o.t));
				}));

			var body = E('div', {}, [
				E('p', {}, _('将对设备 %s（%s）执行踢除。').format(
					(c.hostname || _('未知设备')), c.mac)),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('处理方式')),
					E('div', { 'class': 'cbi-value-field' }, [ sel ])
				]),
				note(_('说明：「踢下线」会让设备立刻断开并重新连接（通常几百毫秒～几秒）。' +
					'选择「停用」时，设备在设定时间内会被拒绝接入本机；停用状态只保存在设备内存中，' +
					'重启或无线重载后自动清除，不会永久拉黑。'))
			]);

			ui.showModal(_('踢除设备'), [
				body,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', click: function (ev) { ev.preventDefault(); ui.hideModal(); } }, _('取消')),
					' ',
					E('button', {
						'class': 'btn cbi-button-negative',
						click: function (ev) {
							ev.preventDefault();
							var sec = sel.value;
							ui.hideModal();
							runClientCmd('client_kick', c.mac + ' ' + sec).then(function (r) {
								toast(r.ok, r.ok ? (r.text || _('已执行')) : (r.text || r.err || _('操作失败')));
								refresh(true);
							});
						}
					}, _('确定'))
				])
			]);
		}

		/* ---- 查看各节点信号（dawn hearing map）----
		   弹窗列出该设备在每个节点/频段上的实测信号（dBm，数值越大越好），
		   本机标「本机」、远端标节点 hostname，最强的一行标绿。空数据给明确提示。 */
		function showSignalMap(c) {
			var title = _('各节点信号') + ' — ' + (c.hostname || c.mac);
			var dlg = E('div', {}, [ E('p', { 'class': 'mesh-muted' }, _('正在读取各节点实测信号…')) ]);
			ui.showModal(title, [
				dlg,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', click: function (ev) { ev.preventDefault(); ui.hideModal(); } }, _('关闭'))
				])
			]);
			runClientCmd('client_signal_map', c.mac).then(function (r) {
				if (!r.ok) {
					while (dlg.firstChild) dlg.removeChild(dlg.firstChild);
					dlg.appendChild(E('p', { 'class': 'mesh-note orange' },
						r.text || r.err || _('读取失败')));
					return;
				}
				var rows = null;
				try { rows = JSON.parse(r.text); } catch (e) { rows = null; }
				if (!Array.isArray(rows) || !rows.length) {
					while (dlg.firstChild) dlg.removeChild(dlg.firstChild);
					dlg.appendChild(E('p', {}, _('暂无该设备在各节点的信号数据（设备可能尚未被各节点测量到，稍后重试）。')));
					return;
				}
				rows.sort(function (a, b) { return Number(a.signal) - Number(b.signal); });
				var best = Number(rows[0].signal);
				var list = E('div', { 'class': 'mesh-sig-list' });
				rows.forEach(function (row) {
					var band = bandShort(row.freq);
					/* ★ 节点标识：本机直接写「本机」；远端**不写主机名** —— 实测同网两台
					   设备主机名可以完全一样（都叫 ponwrt），写出来没有区分度、反而误导。
					   改附 BSSID 前 8 位（AP 的 MAC 前缀），用户可据此在无线页/日志里对上。 */
					var where;
					if (row.local) {
						where = _('本机');
					} else {
						var b = String(row.bssid || '');
						where = b.length >= 8 ? _('其他节点 %s').format(b.slice(0, 8)) : _('其他节点');
					}
					var sig = row.signal + ' dBm';
					var strong = (Number(row.signal) === best) ? ' mesh-sig-best' : '';
					list.appendChild(E('div', { 'class': 'mesh-sig-row' + strong }, [
						E('span', { 'class': 'mesh-sig-where' }, where + (band ? (' · ' + band) : '')),
						E('span', { 'class': 'mesh-sig-val' }, sig)
					]));
				});
				while (dlg.firstChild) dlg.removeChild(dlg.firstChild);
				dlg.appendChild(E('p', { 'class': 'mesh-muted' },
					_('数值为各节点实测到的该设备信号（dBm，数值越大信号越好）。标绿为当前最强；' +
						'「其他节点」后为该 AP 的 BSSID 前缀。')));
				dlg.appendChild(list);
			});
		}

		/* 首次渲染 + 定时刷新（每 15 秒）—— 客户端列表本身是易变的，静态快照参考价值低。
		   操作进行中不做整页替换会更好，但本期先用简单方案（refresh 只在空闲时跑）。 */
		renderInto(payload.clients, true);

		if (this._timer) window.clearInterval(this._timer);
		this._timer = window.setInterval(function () { refresh(true); }, 15000);

		/* 顶部标题栏 + 手动刷新按钮 */
		var btnRefresh = E('button', { 'class': 'btn cbi-button' }, _('刷新'));
		btnRefresh.addEventListener('click', function (ev) {
			ev.preventDefault();
			btnRefresh.disabled = true;
			refresh(false).then(function () { btnRefresh.disabled = false; });
		});

		return E('div', {}, [
			E('h2', {}, _('连接设备')),
			E('div', { 'class': 'mesh-btnrow' }, [ btnRefresh ]),
			host
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
