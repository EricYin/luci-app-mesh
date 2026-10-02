'use strict';
'require view';
'require rpc';
'require ui';

/* ---------- ubus 调用（由 /usr/libexec/rpcd/mesh 提供 mesh 对象） ---------- */
var callMeshStatus = rpc.declare({
	object: 'mesh',
	method: 'status',
	expect: { }
});

var callMeshExec = rpc.declare({
	object: 'mesh',
	method: 'exec',
	params: [ 'cmd' ],
	expect: { stdout: '' }
});

/* ---------- 小工具 ---------- */
/* 拓扑图是把整段 SVG 当字符串拼出来的，所有来自子节点上报的内容(hostname/MAC)
   必须先转义：一来避免把 SVG 结构拼坏，二来这是存储型 XSS 的入口
   —— 任何知道回程密码的设备都能注册，并把 hostname 带到主节点界面上显示 */
function escXml(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

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

function card(label, value, color) {
	var v = E('div', { 'class': 'val' }, String(value == null ? '-' : value));
	if (color) v.style.color = color;
	return E('div', { 'class': 'mesh-card' }, [
		E('div', { 'class': 'lab' }, label),
		v
	]);
}

function pill(text, cls) {
	return E('span', { 'class': 'mesh-pill ' + (cls || 'grey') }, text);
}

/* 后端给的 signal 是 iw 的原始串，形如 "-16 [-18, -20]"（主值 + 相邻信道）。
   JS 里拿这个字符串直接比大小会得到 NaN（`"-16 [...]" >= -70` 恒为 false），
   于是信号条恒为 1 格、拓扑上的无线线恒画成"信号偏弱"橙色 —— 哪怕实测是 -16 dBm。
   因此所有阈值判断都必须先 parseFloat 取出主值，展示时仍用原串。 */
function sigBars(sig) {
	if (sig == null) return E('span', {}, '-');
	var v = parseFloat(String(sig));
	if (isNaN(v)) v = null;
	var n = v == null ? 1 : (v >= -55 ? 4 : v >= -67 ? 3 : v >= -75 ? 2 : 1);
	var color = n >= 3 ? '#37c837' : (n === 2 ? '#f0ad4e' : '#d9534f');
	var bars = E('span', { 'class': 'mesh-sigbars' });
	for (var i = 1; i <= 4; i++)
		bars.appendChild(E('span', {
			'style': 'height:%dpx;background:%s'.format(i * 3 + 3, i <= n ? color : '#ddd')
		}));
	return E('span', {}, [ bars, ' ', E('span', { 'style': 'color:' + color }, sig + ' dBm') ]);
}

function runCmd(cmd, msg) {
	return callMeshExec(cmd).then(function (res) {
		var out = (res && res.stdout) ? res.stdout : '';
		ui.addNotification(null, E('p', {}, msg || (out || _('已完成'))), 'success');
		return out;
	}, function (e) {
		ui.addNotification(null, E('p', {}, _('操作失败：%s').format(e)), 'danger');
		return null;
	});
}

/* ---------- 路径选择说明 ---------- */
function batmanText(d) {
	var b = d.batman || {};
	if (!b.capable)
		return _('802.11s HWMP（未安装 batman-adv）');
	if (b.enabled != 1)
		return _('802.11s HWMP（batman-adv 可用未启用）');
	var t = 'batman-adv';
	if (b.iface) t += ' · ' + b.iface;
	// gw_mode 已经是后端按角色解析后的实际生效值
	if (b.gw_mode && b.gw_mode !== 'auto' && b.gw_mode !== 'off') t += ' · gw ' + b.gw_mode;
	if (b.hardifs && b.hardifs.length) t += ' (' + b.hardifs.join(', ') + ')';
	return t;
}

/* 端口内网化：全部内网端口 + bat0 都在 br-lan 成员表里（主节点不算 WAN 上行口）。
   后端同时核对了 UCI 配置与内核 brif 的真实成员关系 —— 只看 UCI 会出现"写进了
   device 节不认的选项名、界面报绿而内网实际不通"的假象，见 mesh_all_ports_in_lan。 */
function portBridgingText(d) {
	if (d.port_bridging) return _('全部内网端口与 bat0 已并入内网');
	return _('部分端口或 bat0 未并入');
}

function bandText(b) {
	return b === '2g' ? '2.4 GHz' : (b === '6g' ? '6 GHz' : '5 GHz');
}

/* ---------- 拓扑图 ---------- */
function topo(d) {
	var peers = (d.peers && d.peers.list) ? d.peers.list.filter(function (p) { return p.status === 'connected'; }) : [];
	var W = 360, H = Math.max(400, 120 + peers.length * 140);
	var cx = W / 2, cy = H / 2, parts = [];

	parts.push('<circle cx="%d" cy="%d" r="36" fill="#0f8243"/>'.format(cx, cy));
	parts.push('<text x="%d" y="%d" text-anchor="middle" fill="#fff" font-size="13">%s</text>'
		.format(cx, cy + 5, _('本机')));

	peers.forEach(function (p, i) {
		var isWifi = p.link === 'wifi' || p.link === 'both';
		var isWired = p.link === 'wired' || p.link === 'both';
		var x = cx + (i % 2 === 0 ? -95 : 95);
		var y = 80 + Math.floor(i / 2) * 140;
		/* 无线颜色：强度阈值必须先 parseFloat —— p.signal 是 "-16 [-18, -20]" 这样的
		   字符串，直接比大小得 NaN，会恒判为"偏弱"（见 sigBars 的说明） */
		var sigv = parseFloat(String(p.signal == null ? '' : p.signal));
		var good = !isWifi || (!isNaN(sigv) && sigv >= -70);
		var color = isWifi ? (good ? '#37c837' : '#f0ad4e') : '#4a6fa5';

		/* 实际承载的那条画粗实线，另一条画细虚线。
		   这里必须用后端实测的 p.path（来自 br-lan 网桥转发表），**不能**用
		   batman-adv 的 preferred：B 方案下 bat0 只有无线 mesh0 一个 hardif，
		   网线是 br-lan 的桥端口、根本不是 batman 的一条路径，所以 preferred
		   恒为 wifi —— 拿它画图会把"有线在承载"画成细虚线（v1.0.0-r5 及以前）。 */
		var carried = (p.path === 'wired' || p.path === 'wifi') ? p.path : '';
		var wWifi = (carried === 'wifi') ? 4 : (carried ? 1.5 : 2);
		var wWired = (carried === 'wired') ? 4 : (carried ? 1.5 : 2);

		if (isWifi)
			parts.push('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="%d" opacity="0.9"%s/>'
				.format(cx, cy, x, y, color, wWifi, (carried === 'wired' ? ' stroke-dasharray="6,4"' : '')));
		if (isWired)
			parts.push('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#4a6fa5" stroke-width="%d" opacity="0.9"%s%s/>'
				.format(cx, cy, x, y, wWired, (carried === 'wifi' ? ' stroke-dasharray="6,4"' : ''),
					isWifi ? ' transform="translate(6,0)"' : ''));

		var lk = isWifi ? (isWired ? _('无线+有线') : _('无线')) : (p.link === 'unknown' ? _('未知') : _('有线'));
		parts.push('<text x="%d" y="%d" text-anchor="middle" fill="#666" font-size="10">%s</text>'
			.format(cx + (x > cx ? 40 : -40), (cy + y) / 2 - 4, lk));
		parts.push('<circle cx="%d" cy="%d" r="27" fill="%s"/>'.format(x, y, color));
		parts.push('<text x="%d" y="%d" text-anchor="middle" fill="#fff" font-size="11">%s</text>'
			.format(x, y + 4, isWifi ? ((p.signal != null ? p.signal + 'dBm' : _('无线'))) : '1G'));
		var suffix = p.role === 'master' ? ' ★' : (p.index ? ' #' + p.index : '');
		parts.push('<text x="%d" y="%d" text-anchor="middle" fill="%s" font-size="10">%s%s</text>'
			.format(x, y + 46, p.role === 'master' ? '#0f8243' : '#666',
				escXml(p.hostname || p.mac), suffix));
		if (p.bat && p.bat.tq != null)
			parts.push('<text x="%d" y="%d" text-anchor="middle" fill="#0f8243" font-size="10">TQ %d</text>'
				.format(x, y + 60, parseInt(p.bat.tq, 10)));
	});

	if (!peers.length)
		parts.push('<text x="%d" y="%d" text-anchor="middle" fill="#999" font-size="12">%s</text>'
			.format(cx, cy + 70, _('暂无已连接邻居')));

	/* 用 div.innerHTML 承载完整 <svg> 字符串：HTML 解析器会把 svg 及其子元素放进
	   SVG 命名空间，比 E('svg') + innerHTML 更可靠（各浏览器对 createElement('svg')
	   是否返回 SVGSVGElement 的行为并不一致） */
	var box = E('div', { 'class': 'mesh-topo-svg' });
	box.innerHTML = '<svg viewBox="0 0 ' + W + ' ' + H + '" width="100%" height="' + H
		+ '" style="max-width:440px">' + parts.join('') + '</svg>';
	return box;
}

/* ---------- 回滚保护条 ---------- */
function rollbackBox(d) {
	var rb = d.rollback;
	/* 没有回滚窗口时返回空节点而非 null：LuCI 的 E() 会把 null 子节点渲染成字面量
	   "null"，导致组网状态页顶部冒出一个 <div>null</div>（2026-09-23 真机复现）。 */
	if (!rb || !rb.active) return E('div');

	var txt = _('新配置已生效。若 %d 分钟内无法通过新地址访问本设备%s，系统将自动还原到组网前的配置。现在能正常访问请点「保留新配置」。')
		.format(Math.ceil((rb.remain || 0) / 60), (rb.ip && rb.ip !== '-') ? '(' + rb.ip + ')' : '');

	var btnKeep = E('button', { 'class': 'btn cbi-button-apply' }, _('可以访问，保留新配置'));
	btnKeep.addEventListener('click', function () {
		btnKeep.disabled = true;
		btnKeep.textContent = _('确认中…');
		runCmd('confirm_rollback').then(function () {
			btnKeep.disabled = false;
			btnKeep.textContent = _('可以访问，保留新配置');
		});
	});

	var btnBack = E('button', { 'class': 'btn cbi-button-negative' }, _('无法访问，立即还原'));
	btnBack.addEventListener('click', function () {
		if (!confirm(_('将还原到组网前的配置，无线与网络会重启。确定继续？'))) return;
		runCmd('revert');
	});

	return E('div', { 'class': 'mesh-rollback' }, [
		E('b', {}, _('回滚保护窗口')),
		E('div', { 'style': 'margin:6px 0 10px;font-size:13px;line-height:1.7' }, txt),
		E('div', { 'class': 'mesh-btnrow' }, [ btnKeep, btnBack ])
	]);
}

/* ---------- batman-adv 链路质量 ---------- */
/* 这里**只**报告 batman-adv 自己的口径：TQ 和它选中的 hardif 出口。
   不要再拿 preferred 推"优先链路" —— batman 看不到网线（网线是 br-lan 的桥端口，
   不是 bat0 的 hardif），它的出口恒为无线 mesh0，写成"优先：无线"就会和"实际在
   走网线"直接矛盾。实际承载哪条链路由后端实测，显示在「链路」列。 */
function batCell(p) {
	var b = p.bat;
	if (!b || b.tq == null)
		return E('td', {}, E('span', { 'style': 'color:#999' }, '-'));

	var tq = parseInt(b.tq, 10);
	var pct = Math.round(tq / 255 * 100);
	var color = tq >= 200 ? '#37c837' : (tq >= 120 ? '#f0ad4e' : '#d9534f');
	var parts = [];
	if (b.via) parts.push(_('batman 出口 %s').format(b.via));
	if (b.gw) parts.push(_('出网网关'));

	return E('td', {}, [
		E('div', { 'style': 'font-weight:600;color:' + color }, 'TQ ' + tq + '/255 (' + pct + '%)'),
		E('div', { 'class': 'mesh-tag' }, parts.join(' · '))
	]);
}

/* ---------- 邻居表 ---------- */
function peersTable(d) {
	var list = (d.peers && d.peers.list) ? d.peers.list : [];
	var hasBat = list.some(function (p) { return p.bat && p.bat.tq != null; });

	var heads = [
		E('th', {}, _('邻居节点')),
		E('th', {}, _('链路')),
		E('th', {}, _('信号 / 速率')),
		E('th', {}, _('地址'))
	];
	if (hasBat) heads.push(E('th', {}, _('链路质量 (batman-adv)')));
	heads.push(E('th', {}, _('链路状态')));

	var table = E('table', { 'class': 'mesh-table' }, [ E('tr', {}, heads) ]);

	if (!list.length)
		return E('div', {}, [
			E('div', { 'class': 'mesh-table-empty' }, _('暂无已连接的邻居节点'))
		]);

	list.forEach(function (p) {
		var isWifi = p.link === 'wifi' || p.link === 'both';
		var isWired = p.link === 'wired' || p.link === 'both';

		var tags = [];
		if (p.role === 'master')
			tags.push(pill(_('主节点'), 'ok'));
		else if (p.role === 'unknown')
			tags.push(pill(_('未登记'), 'grey'));
		if (p.index)
			tags.push(E('span', {}, _('节点#%d').format(p.index)));

		var nameCell = E('td', {}, [
			E('div', { 'style': 'font-weight:600' }, [
				p.hostname || p.mac,
				' ',
				E('span', { 'style': 'font-weight:400' }, tags.length ? tags : '')
			]),
			E('div', { 'class': 'mesh-tag' }, p.mac)
		]);

		var linkTags = p.link === 'both'
			? [ pill(_('无线'), 'green'), ' ', pill(_('有线'), 'blue') ]
			: (p.link === 'wifi' ? [ pill(_('无线'), 'green') ]
				: (p.link === 'wired' ? [ pill(_('有线'), 'blue') ]
					: [ (p.link === 'unknown' ? pill(_('路径未知'), 'grey') : pill(p.link || '?', 'grey')) ]));
		/* 两条链路都在线时必须点明数据实际走哪条 —— 这正是"页面上无线和有线都接入了，
		   为什么还显示无线优先"这个疑问的答案所在。后端按 br-lan 内核转发表实测给出
		   p.path（batman-adv 看不到网线，问它只会得到"无线"）。 */
		if (p.link === 'both' && (p.path === 'wired' || p.path === 'wifi')) {
			var pw = (p.path === 'wired');
			linkTags.push(E('div', {
				'style': 'font-size:11px;margin-top:2px;color:' + (pw ? '#4a6fa5' : '#0f8243')
			}, _('实际承载：%s').format(pw ? _('有线') : _('无线'))));
		}
		var linkCell = E('td', {}, linkTags);

		var sigCell;
		if (p.status !== 'connected') {
			sigCell = E('td', {}, E('span', { 'style': 'color:#999' }, '-'));
		} else if (isWifi) {
			sigCell = E('td', {}, [
				sigBars(p.signal), ' · ', E('span', {}, p.txrate || '-'),
				isWired ? E('div', { 'style': 'font-size:11px;color:#4a6fa5;margin-top:2px' }, _('+ 有线 1000 Mb/s')) : ''
			]);
		} else {
			sigCell = E('td', {}, [
				E('span', { 'style': 'font-weight:600;color:#4a6fa5' }, '1000 Mb/s'),
				E('span', { 'style': 'color:#999;font-size:12px' }, ' · ' + _('全双工'))
			]);
		}

		var ipCell = E('td', { 'class': 'mesh-tag' }, p.ip || '-');

		var stCell = E('td', {});
		if (p.status === 'connected') {
			stCell.appendChild(pill(_('已连接'), 'ok'));
			if (p.connected)
				stCell.appendChild(E('div', {
					'style': 'font-size:11px;color:#999;margin-top:2px'
				}, _('连接时长 %s s').format(p.connected)));
		} else {
			stCell.appendChild(pill(_('离线'), 'grey'));
		}

		var cells = [ nameCell, linkCell, sigCell, ipCell ];
		if (hasBat) cells.push(batCell(p));
		cells.push(stCell);
		table.appendChild(E('tr', {}, cells));
	});

	return table;
}

/* ---------- 视图 ---------- */
return view.extend({
	pollInterval: 10,

	load: function () {
		return callMeshStatus();
	},

	render: function (d) {
		ensureCss();
		d = d || {};

		/* 能力检测 */
		var cap = d.capabilities || {};
		var ok = cap.kernel_mesh && cap.wpad_mesh && cap.batman && cap.batctl;
		/* 漫游引导（dawn + umdns）不是组网的前置条件 —— 缺了照样能组 mesh，
		   只是客户端不会被引导到更优的 AP。所以单独判定：缺失时只把提示框降级为
		   橙色提醒，不整框变红（否则没装 dawn 的设备会被误报成"组网不可用"）。 */
		var roamOk = cap.dawn && cap.umdns;
		var capBox = E('div', { 'class': 'mesh-note ' + (ok ? (roamOk ? 'green' : 'orange') : 'red') });
		if (ok) {
			var t2 = _('无线驱动已上报 mesh point 能力，已安装完整版 wpad，且已具备 batman-adv 内核模块与 batctl —— 802.11s 组网可用。');
			if (roamOk) {
				t2 += ' ' + _('漫游引导已就绪（dawn + umdns）：客户端会被引导到信号更优的 AP。');
			} else {
				t2 += ' ' + _('但缺少漫游引导：');
				if (!cap.dawn) t2 += ' ' + _('需安装 dawn；');
				if (!cap.umdns) t2 += ' ' + _('需安装 umdns（dawn 的邻居发现）。');
				t2 += ' ' + _('客户端不会主动切换 AP（组网本身不受影响）。');
			}
			capBox.textContent = t2;
		} else {
			var t = _('组网能力不满足：');
			if (!cap.kernel_mesh) t += ' ' + _('驱动未上报 mesh point；');
			if (!cap.wpad_mesh) t += ' ' + _('需安装 wpad-openssl / wpad-wolfssl。');
			if (!cap.batman) t += ' ' + _('需安装 kmod-batman-adv batctl。');
			/* 内核模块在但 batctl 二进制缺失：界面不能显示全绿，否则 apply 会被静默拒绝 */
			if (cap.batman && !cap.batctl) t += ' ' + _('已装 batman-adv 内核模块但缺少 batctl 工具。');
			if (!cap.dawn) t += ' ' + _('缺少漫游引导 dawn；');
			if (!cap.umdns) t += ' ' + _('缺少 dawn 的邻居发现组件 umdns。');
			capBox.textContent = t;
		}

		/* 运行状态卡片 */
		var on = d.enabled == 1;
		var isClient = d.role === 'client';
		var pr = d.peers || {};
		var nConn = pr.connected || 0;
		/* 邻居卡片：一台设备同时走无线+有线只算一个节点 */
		var cardVal = nConn + (nConn ? ' (%s %s / %s %s)'.format(pr.wifi || 0, _('无线'), pr.eth || 0, _('有线')) : '');
		var cards = E('div', { 'class': 'mesh-cards' }, [
			card(_('Mesh 状态'), on ? _('已启用') : _('未启用'), on ? '#37c837' : '#999'),
			card(_('Mesh ID'), d.mesh_id),
			card(_('已连接邻居'), cardVal, nConn > 0 ? '#37c837' : null),
			card(_('路径选择'), batmanText(d), (d.batman && d.batman.enabled == 1) ? '#37c837' : null),
			card(_('本机角色'), isClient ? _('子节点(全端口内网 · 跟随主节点)') : _('主节点(接光猫 · 配置源)')),
			card(_('本机地址'), d.lan_ip),
			card(_('地址获取'),
				isClient ? ((d.lan_proto === 'dhcp') ? _('DHCP(从主节点获取)') : _('静态(本机保留)')) : _('本机静态')),
			card(_('回程接口'), (d.backhaul && d.backhaul.ifname && d.backhaul.ifname !== '-')
				? '%s (CH %s)'.format(d.backhaul.ifname, d.backhaul.channel) : _('未运行')),
			card(_('配置同步'), isClient ? ((d.sync && d.sync.state) || '-')
				: _('下发中(作为配置源)'),
				isClient ? ((d.sync && d.sync.code === 'ok') ? '#37c837' : '#f0ad4e') : '#37c837'),
			card(_('上次同步'), (d.sync && d.sync.last_ok) || '-'),
			card(_('端口内网化'), portBridgingText(d), d.port_bridging ? '#37c837' : '#f0ad4e')
		]);

		/* 图例：线的粗细/虚实表示"谁在实际承载"，颜色表示链路类型与质量 */
		var legend = E('div', {}, [
			E('div', { 'class': 'mesh-topo-legend' }, [
				E('span', {}, [ E('i', { 'style': 'border-top:4px solid #4a6fa5' }), _('粗实线 = 实际承载(有线)') ]),
				E('span', {}, [ E('i', { 'style': 'border-top:4px solid #37c837' }), _('粗实线 = 实际承载(无线)') ]),
				E('span', {}, [ E('i', { 'style': 'border-top:2px dashed #bbb' }), _('细虚线 = 备用链路') ]),
				E('span', {}, [ E('i', { 'style': 'border-top:2px solid #f0ad4e' }), _('无线信号偏弱') ])
			]),
			E('div', { 'class': 'mesh-muted' },
				_('承载链路按 br-lan 内核转发表实测：batman-adv 只认无线 hardif，网线是桥端口，它看不到。'))
		]);

		/* 操作区已整体移除（2026-09-23）：原「立即应用配置」由组网设置页保存时 LuCI 自动应用，
		   「立即同步一次」在主节点是空操作，故状态页不再保留手动操作入口。 */
		var rb = rollbackBox(d);

		return E('div', {}, [
			rb,
			section(_('能力检测'), capBox),
			section(_('运行状态'), cards),
			section(_('网络拓扑'), [ E('div', { 'class': 'mesh-topo-wrap' }, topo(d)), legend ]),
			section(_('邻居节点'), peersTable(d))
		]);
	}
});
