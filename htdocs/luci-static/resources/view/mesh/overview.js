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
			.format(cx, cy + 70, _('暂无已连接节点')));

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

/* ---------- 节点表 ---------- */
function peersTable(d) {
	var list = (d.peers && d.peers.list) ? d.peers.list : [];
	var hasBat = list.some(function (p) { return p.bat && p.bat.tq != null; });

	var heads = [
		E('th', {}, _('节点')),
		E('th', {}, _('链路')),
		E('th', {}, _('信号 / 速率')),
		E('th', {}, _('地址'))
	];
	if (hasBat) heads.push(E('th', {}, _('链路质量 (batman-adv)')));
	heads.push(E('th', {}, _('链路状态')));

	var table = E('table', { 'class': 'mesh-table' }, [ E('tr', {}, heads) ]);

	if (!list.length)
		return E('div', {}, [
			E('div', { 'class': 'mesh-table-empty' }, _('暂无已连接的节点'))
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

/* ---------- 一键加入（配对） ---------- */
/* 界面侧只有三件事：开窗 / 关窗 / 加入，全部走后台执行——它们都要动无线，
   pair-join 还要等主节点开窗并紧接着跑一次 apply（子节点会换 IP + 重启网络），
   同步等只会让 RPC 超时。所以点了就立刻返回，真实进度靠 status 里的
   pair.progress 轮询（页面本身 10 秒一轮，忙时另开 3 秒一轮的快轮询）。 */
var callMeshPair = rpc.declare({
	object: 'mesh',
	method: 'exec',
	params: [ 'cmd', 'arg' ],
	expect: { stdout: '', code: 0 }
});

/* 倒计时用的本地定时器与"忙时快轮询"定时器。
   页面每 10 秒会整体重渲染一次，不清掉旧定时器就会越积越多（每轮多一个
   每秒跑的 interval），所以每次渲染前统一清理。 */
var pairTimers = [];
var pairBusyTimer = null;
var pairHost = null;

function clearPairTimers() {
	pairTimers.forEach(function (t) { clearInterval(t); });
	pairTimers = [];
}

function fmtDur(s) {
	s = Math.max(0, parseInt(s, 10) || 0);
	var m = Math.floor(s / 60), sec = s % 60;
	return m > 0 ? ('%d 分 %02d 秒'.format(m, sec)) : ('%d 秒'.format(sec));
}

/* 剩余时间倒计时：后端给的 remain 是"此刻还剩多少秒"，本地按秒自减。
   不用服务端绝对时间戳，避免设备与浏览器时钟不一致导致显示跳变。 */
function countdown(remain, onEnd) {
	var left = parseInt(remain, 10) || 0;
	var span = E('span', { 'style': 'font-weight:600' }, fmtDur(left));
	var t = setInterval(function () {
		left--;
		if (left <= 0) {
			clearInterval(t);
			span.textContent = _('已到期，正在自动关闭');
			if (onEnd) { onEnd(); }
		} else {
			span.textContent = fmtDur(left);
		}
	}, 1000);
	pairTimers.push(t);
	return span;
}

function pairOpTitle(op) {
	if (op === 'pair_open') { return _('正在开放加入…'); }
	if (op === 'pair_close') { return _('正在关闭加入窗口…'); }
	if (op === 'pair_join') { return _('正在加入网络…'); }
	return _('正在处理…');
}

/* 后台跑完之前的快轮询：3 秒一次，直到 busy 消失为止。
   只重画配对这一块，不动整页（整页重画会把拓扑图也重建，闪得厉害）。 */
function watchPair() {
	if (pairBusyTimer) { return; }
	pairBusyTimer = setInterval(function () {
		callMeshStatus().then(function (d) {
			var pr = (d && d.pair && d.pair.progress) || {};
			repaintPair(d || {});
			if (pr.busy != 1) {
				clearInterval(pairBusyTimer);
				pairBusyTimer = null;
			}
		}, function () { /* 拉不到就等下一轮 */ });
	}, 3000);
}

function repaintPair(d) {
	if (!pairHost) { return; }
	clearPairTimers();
	pairHost.innerHTML = '';
	pairHost.appendChild(pairSection(d));
}

function doPair(cmd, arg) {
	return callMeshPair(cmd, arg).then(function (res) {
		var out = (res && res.stdout) ? res.stdout : '';
		ui.addNotification(null, E('p', {}, out || _('已触发')), 'success');
		/* 立刻快轮询一次：不等页面 10 秒的常规刷新，进度马上可见 */
		setTimeout(function () {
			callMeshStatus().then(repaintPair, function () {});
		}, 1200);
		watchPair();
		return out;
	}, function (e) {
		ui.addNotification(null, E('p', {}, _('操作失败：%s').format(e)), 'danger');
		return null;
	});
}

function pairSection(d) {
	var p = d.pair || {};
	var prog = p.progress || {};
	var last = prog.last || {};
	var busy = (prog.busy == 1);
	var on = (d.enabled == 1);
	var roleSet = (d.role_set !== 0);
	var isClient = (d.role === 'client');

	/* 标题由 render() 统一渲染（放进 .cbi-section 里），这里只产出区块内容：
	   重画时只换内容、不换外壳，也不会把标题画两遍 */
	var box = E('div', {}, [
		E('div', { 'class': 'mesh-muted', 'style': 'margin:4px 0 10px;line-height:1.8' },
			_('新节点不必手工填 Mesh ID 与回程密码：主节点点「开放加入」临时起一个配对信号'
				+ '（固件固定的 SSID/密码），新节点连上来领走凭证并自动生效。'
				+ '窗口到期自动关闭；窗口关着时配对信号根本不存在，所以固定密码本身不构成风险。'))
	]);

	/* A. 还没启用 / 还没选角色：任何配对动作都没有意义，直接挡掉并给出可执行的下一步。
	   子节点这段提示特意点明"先点保存、别点保存并应用" —— 凭证还没领到的时候跑
	   apply 必然报「子节点没有 Mesh ID」，那是预期内的失败，不该让用户以为是坏了。 */
	if (!roleSet || !on) {
		var hint;
		if (!roleSet) {
			hint = _('未设置本节点角色：请先到「组网设置」选择主节点或子节点并保存。');
		} else if (isClient) {
			hint = _('Mesh 组网尚未启用：请到「组网设置」把「启用 Mesh 组网」打开、'
				+ '角色选「子节点」，然后点『保存』——**先别点「保存并应用」**，'
				+ '凭证还没领到，这时应用会报「子节点没有 Mesh ID」。保存完回到本页点下面的按钮。');
		} else {
			hint = _('Mesh 组网尚未启用：请先到「组网设置」打开「启用 Mesh 组网」并保存应用，'
				+ '主节点只有启用后才能开放加入。');
		}
		box.appendChild(E('div', { 'class': 'mesh-note red' }, hint));
		return box;
	}

	/* 上一次后台操作的真实结果（code=2 = 尚无记录，不显示） */
	if (last.code != null && last.code !== 2) {
		var ok = (last.code === 0);
		box.appendChild(E('div', {
			'style': 'margin:0 0 10px;padding:.6em .8em;border-radius:4px;font-size:90%;background:'
				+ (ok ? '#e8f5e9' : '#ffebee') + ';color:' + (ok ? '#1b5e20' : '#b71c1c')
		}, _(ok ? '上次配对操作：成功' : '上次配对操作：失败')
			+ (last.time ? '（' + last.time + '）' : '')
			+ (last.msg ? ' —— ' + last.msg : '')));
	}

	/* 进度条：pair-join 会依次打出 [1/4]…[4/4]，把它原样显示出来最好懂 */
	if (busy) {
		box.appendChild(E('div', { 'class': 'mesh-note orange' }, [
			E('b', {}, pairOpTitle(prog.op)),
			E('div', { 'style': 'margin-top:4px' }, prog.tail || _('处理中…'))
		]));
	}

	var row = E('div', { 'class': 'mesh-btnrow' });

	if (isClient) {
		/* D. 子节点：一个「一键加入」按钮。
		   先后顺序无所谓——点完之后它会一直等到主节点开窗为止（默认 5 分钟），
		   所以文案必须说清"现在可以去主节点点开放加入"。 */
		if (d.mesh_id) {
			box.appendChild(E('div', { 'class': 'mesh-tag', 'style': 'margin-bottom:8px' },
				_('当前 Mesh ID：%s（已入网；换网络或凭证丢失时可重新加入）').format(d.mesh_id)));
		} else {
			box.appendChild(E('div', { 'class': 'mesh-tag', 'style': 'margin-bottom:8px' },
				_('尚未获取组网凭证（Mesh ID 为空）—— 点下面的按钮自动领取。')));
		}

		var btnJoin = E('button', {
			'class': 'btn cbi-button-apply', 'type': 'button',
			'style': busy ? 'opacity:.5' : ''
		}, busy && prog.op === 'pair_join' ? _('加入中…') : _('一键加入网络'));
		btnJoin.disabled = busy;
		btnJoin.addEventListener('click', function () {
			if (busy) { return; }
			if (!confirm(_('将临时连到配对信号领取组网凭证，并立即应用组网。'
				+ '应用后本机管理地址会改由主节点分配（出厂地址会变）。确定继续？'))) { return; }
			doPair('pair_join', 'apply');
		});
		row.appendChild(btnJoin);
		box.appendChild(row);
		box.appendChild(E('div', { 'class': 'mesh-muted', 'style': 'margin-top:6px' },
			_('点完这个按钮再去主节点的「组网状态」页点「开放加入」，两边顺序不分先后：'
				+ '本节点会等待最长 %s，期间每 10 秒重试一次。').format(fmtDur(p.wait || 300))));
		box.appendChild(E('div', { 'class': 'mesh-muted' },
			_('也可以命令行执行：meshctl pair-join --apply')));
		return box;
	}

	/* B / C. 主节点 */
	if (p.open == 1) {
		var cards = E('div', { 'class': 'mesh-cards' }, [
			card(_('配对信号 (SSID)'), p.ssid || '-'),
			card(_('配对密码'), p.key || 'xxmesh-pair'),
			card(_('所在射频'), p.radio || '-'),
			card(_('本轮已加入'), '%s %s'.format(p.joined || 0, _('台')))
		]);
		box.appendChild(cards);

		var line = E('div', { 'style': 'margin:10px 0;font-size:14px' }, [
			E('b', { 'style': 'color:#37c837' }, _('已开放加入')),
			' · ',
			(p.remain == -1 ? _('常开（不会自动关闭）') : countdown(p.remain, function () {
				setTimeout(function () { callMeshStatus().then(repaintPair, function () {}); }, 3000);
			}))
		]);
		box.appendChild(line);
		box.appendChild(E('div', { 'class': 'mesh-muted', 'style': 'margin-bottom:8px' },
			_('新节点连上这个信号后会自动领走 Mesh ID 与回程密码。所有已入网的子节点也会'
				+ '自动广播同一个配对信号（走现有的 AP 镜像），新节点可以连信号最好的那个。')));

		var btnClose = E('button', { 'class': 'btn cbi-button-negative', 'type': 'button' },
			_('立即关闭'));
		btnClose.disabled = busy;
		btnClose.addEventListener('click', function () { doPair('pair_close'); });
		row.appendChild(btnClose);
	} else {
		var sel = E('select', { 'class': 'cbi-input-select', 'style': 'max-width:14em' }, [
			E('option', { 'value': '120' }, _('2 分钟')),
			E('option', { 'value': '300' }, _('5 分钟')),
			E('option', { 'value': '600' }, _('10 分钟（默认）')),
			E('option', { 'value': '1800' }, _('30 分钟')),
			E('option', { 'value': '0' }, _('常开（不自动关闭）'))
		]);
		sel.value = String(p.window == null ? 600 : p.window);
		/* 配置里的值不在预设里时（比如手工填了 900），补一个选项，避免静默变成 600 */
		if (sel.value !== String(p.window == null ? 600 : p.window)) {
			sel.appendChild(E('option', { 'value': String(p.window) }, fmtDur(p.window)));
			sel.value = String(p.window);
		}

		var btnOpen = E('button', { 'class': 'btn cbi-button-apply', 'type': 'button' },
			_('开放加入'));
		btnOpen.disabled = busy;
		btnOpen.addEventListener('click', function () { doPair('pair_open', sel.value); });

		row.appendChild(sel);
		row.appendChild(btnOpen);
		box.appendChild(row);
		box.appendChild(E('div', { 'class': 'mesh-muted', 'style': 'margin-top:6px' },
			_('开放后本节点会临时多一个配对信号（桥在内网上），到期自动撤掉。'
				+ '窗口期内任何"连得上本节点、知道固件固定配对密码"的设备都能领到凭证，'
				+ '所以默认只开几分钟——兜底就是"得本人在现场开窗"。')));
		return box;
	}

	box.appendChild(row);
	return box;
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

		/* 角色没落盘时的红框：后端不再把空 role 兜底成 master（status 里给 role_set=0），
		   这里必须显眼提示 —— 否则界面照旧写"主节点 · 配置源(下发中)"，而 apply 在
		   第一步就退出、mesh0/bat0 建不起来、子节点只能拿到 not_master。
		   真机踩到过（2026-10-02）。 */
		var roleBox = null;
		if (d.role_set === 0) {
			roleBox = E('div', { 'class': 'mesh-note red' });
			roleBox.textContent = _('未设置本节点角色：/etc/config/mesh 里没有 mesh.main.role，组网不会生效。')
				+ ' ' + _('请到「组网设置」选择主节点或子节点后保存并应用，或执行：uci set mesh.main.role=master; uci commit mesh');
		}

		/* 运行状态卡片 */
		var on = d.enabled == 1;
		var isClient = d.role === 'client';
		var pr = d.peers || {};
		var nConn = pr.connected || 0;
		/* 节点卡片：一台设备同时走无线+有线只算一个节点 */
		var cardVal = nConn + (nConn ? ' (%s %s / %s %s)'.format(pr.wifi || 0, _('无线'), pr.eth || 0, _('有线')) : '');
		var cards = E('div', { 'class': 'mesh-cards' }, [
			card(_('Mesh 状态'), on ? _('已启用') : _('未启用'), on ? '#37c837' : '#999'),
			/* Mesh ID 为空 = 还没生成过（出厂默认留空）。这里如实说明，
			   不要显示成"未设置"以外的假值，也不要替用户猜测。 */
			card(_('Mesh ID'), d.mesh_id
				|| (isClient ? _('未设置（从主节点获取）') : _('未设置（应用后按 MAC 自动派生）'))),
			card(_('已连接节点'), cardVal, nConn > 0 ? '#37c837' : null),
			card(_('路径选择'), batmanText(d), (d.batman && d.batman.enabled == 1) ? '#37c837' : null),
			card(_('本机角色'), d.role_set === 0
				? _('未选择')
				: (isClient ? _('子节点(全端口内网 · 跟随主节点)') : _('主节点(上网网关 · 配置源)')),
				d.role_set === 0 ? '#e24b4a' : null),
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

		/* 配对卡片放在「运行状态」之后：它是"加新节点"的入口，属于状态页的高频操作，
		   比拓扑图更该被先看到。放在最上面又会挤掉能力检测的红框，故居中。 */
		clearPairTimers();
		pairHost = E('div', { 'class': 'cbi-section-node' });
		pairHost.appendChild(pairSection(d));
		var pairSec = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('一键加入（新节点免配置入网）')),
			pairHost
		]);

		return E('div', {}, [
			rb,
			roleBox,
			section(_('能力检测'), capBox),
			section(_('运行状态'), cards),
			pairSec,
			section(_('网络拓扑'), [ E('div', { 'class': 'mesh-topo-wrap' }, topo(d)), legend ]),
			section(_('节点列表'), peersTable(d))
		]);
	}
});
