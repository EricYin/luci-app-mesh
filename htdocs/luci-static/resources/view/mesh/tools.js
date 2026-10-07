'use strict';
'require view';
'require rpc';
'require ui';

var callMeshStatus = rpc.declare({
	object: 'mesh',
	method: 'status',
	expect: { }
});

var callMeshExec = rpc.declare({
	object: 'mesh',
	method: 'exec',
	params: [ 'cmd' ],
	/* ★ expect is NOT a default-value filler: LuCI walks its keys and RESOLVES
	   ret = ret[key] (first key only, then break). So `expect:{stdout:''}`
	   makes the call resolve the stdout STRING, not {code,stdout} — and any
	   caller doing res.stdout gets undefined forever. Use {} for the full object. */
	expect: { }
});

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

function bandText(b) {
	return b === '2g' ? '2.4 GHz' : (b === '6g' ? '6 GHz' : '5 GHz');
}

var callMeshExecArg = rpc.declare({
	object: 'mesh',
	method: 'exec',
	params: [ 'cmd', 'arg' ],
	expect: { }   /* see callMeshExec: {} = full {code,stdout} object */
});

/* Accept both shapes: string (older/newer LuCI may resolve expect[0] directly)
   or the {code,stdout} object. Never lose the payload silently. */
function pickStdout(res) {
	if (typeof res === 'string') { return res; }
	return (res && res.stdout) ? res.stdout : '';
}

function runCmd(cmd) {
	return callMeshExec(cmd).then(function (res) {
		return (res && res.stdout) ? res.stdout : '';
	}, function (e) {
		ui.addNotification(null, E('p', {}, _('操作失败：%s').format(e)), 'danger');
		return null;
	});
}

/* 带附加参数的调用（目前只有 log 用：arg = "行数" 或 "行数 --syslog"）
   ★ 返回结构化结果而不是"失败就给空串"：早期版本把调用失败静默成 ''，界面只能显示
     「暂无日志记录」，看不出到底是日志真为空、还是 RPC 根本没成功 —— 排查时极坑。
     现在 ok=false 时界面会把错误原因直接写出来。 */
function runCmdArg(cmd, arg) {
	return callMeshExecArg(cmd, arg).then(function (res) {
		return {
			ok: true,
			text: pickStdout(res),
			code: (res && typeof res === 'object') ? res.code : undefined
		};
	}, function (e) {
		return { ok: false, err: String((e && e.message) ? e.message : e) };
	});
}

/* ---------- 射频表 ---------- */
function radiosTable(d) {
	var radios = (d && d.radios) ? d.radios : [];
	if (!radios.length)
		return E('div', { 'class': 'mesh-table-empty' }, _('未读取到射频信息'));

	var table = E('table', { 'class': 'mesh-table' }, [
		E('tr', {}, [
			E('th', {}, _('射频')),
			E('th', {}, _('物理接口')),
			E('th', {}, _('频段')),
			E('th', {}, _('当前信道')),
			E('th', {}, _('信道来源'))
		])
	]);

	radios.forEach(function (r) {
		var chTxt = (r.channel === 'auto')
			? (_('自动') + (r.real ? ' (' + _('实际 %d').format(r.real) + ')' : ''))
			: String(r.channel);

		/* 信道来源：auto=跟随驱动；回程频段=与主节点同信道；其余固定信道=按节点序号错开 */
		var src = _('主节点');
		if (r.channel === 'auto')
			src = _('自动(驱动)');
		else if (d.role === 'client' && d.backhaul && r.band === d.backhaul.band)
			src = _('回程同步(与主节点同信道)');
		else if (d.sync && d.sync.my_index > 0 && d.role === 'client')
			src = _('已错开(节点#%d)').format(d.sync.my_index);

		table.appendChild(E('tr', {}, [
			E('td', {}, r.radio),
			E('td', {}, r.phy),
			E('td', {}, bandText(r.band)),
			E('td', {}, chTxt),
			E('td', {}, src)
		]));
	});

	return table;
}

/* ---------- 视图 ---------- */
return view.extend({
	pollInterval: 15,

	load: function () {
		return callMeshStatus();
	},

	render: function (d) {
		ensureCss();
		d = d || {};

		/* ---------- 能力检测 ---------- */
		/* 2026-10-07 从「组网状态」页整段移来：它回答的是"这台设备到底能不能组网"，
		   属于排查信息，和本页的射频能力表是一类，放最前面。 */
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

		/* 维护 */
		var bkTime = (d && d.backup_created) ? d.backup_created : '';
		var btnRevert = E('button', { 'class': 'btn cbi-button-negative' }, _('退出组网-还原组网前配置'));
		btnRevert.addEventListener('click', function () {
			var msg = _('确定要退出组网并还原到组网前的配置吗？');
			if (bkTime)
				msg += '\n\n' + _('备份创建于：%s').format(bkTime);
			msg += '\n\n' + _('该时刻之后修改的 WiFi 名称密码、防火墙、DHCP 都会丢失；')
				+ _('还原后需要重新选择本节点角色（主节点 / 子节点）再应用。')
				+ '\n' + _('配置会重新加载使生效，通常无需重启路由器。');
			if (!confirm(msg)) return;
			runCmd('revert').then(function (text) {
				ui.addNotification(null, E('p', {}, text || _('已退出组网并还原组网前配置')), 'success');
			});
		});

		var btnRefreshBk = E('button', { 'class': 'btn' }, _('刷新备份'));
		btnRefreshBk.addEventListener('click', function () {
			var msg = _('刷新会用当前配置重建「组网前备份」，并自动剔除组网相关内容：')
				+ '\n\n· ' + _('无线里的 mesh 回程段、配对 AP 段')
				+ '\n· ' + _('网络里的 bat0 / batmesh 接口及桥成员')
				+ '\n· ' + _('组网凭证（Mesh ID、密钥、主节点地址、节点角色）')
				+ '\n\n' + _('保留：WiFi 名称密码、LAN 地址、端口分配、防火墙、DHCP、按键档位等个人设置。')
				+ '\n\n' + _('★ 刷新会覆盖现有的组网前备份（旧备份会先留存为 /etc/mesh-backup.prev），是否继续？');
			if (!confirm(msg)) return;
			runCmd('backup-refresh').then(function (text) {
				ui.addNotification(null, E('p', {}, text || _('备份已刷新')), 'success');
			});
		});

		var btnPorts = E('button', { 'class': 'btn' }, _('端口并入内网(手动)'));
		btnPorts.addEventListener('click', function () {
			runCmd('port_bridging').then(function (text) {
				ui.addNotification(null, E('p', {}, text || _('端口并入操作已执行')), 'success');
			});
		});

		var bkState = d && d.backup_exists
			? '· ' + _('组网前备份创建于：%s').format(bkTime || _('未知'))
			: '· ' + _('尚未创建备份 —— 首次应用组网配置时会自动创建。');

		var tips = E('div', { 'class': 'mesh-muted' }, [
			E('div', {}, bkState),
			E('div', {}, '· ' + _('「退出组网-还原组网前配置」会恢复该备份并清除 Mesh 凭证，适合组网失败或想回到普通路由模式时使用（与「组网状态」页配对区块的「退出组网」是同一个操作）。')),
			E('div', {}, '· ' + _('「刷新备份」用当前配置重建还原点（剔除组网相关配置），适合组网很久以后更新还原点。')),
			E('div', {}, '· ' + _('「端口并入内网」把所有物理端口(WAN/LAN)加入 br-lan，子节点应用配置时也会自动执行。'))
		]);

		var maintSec = section(_('维护'), [
			E('div', { 'class': 'mesh-btnrow' }, [ btnRevert, btnRefreshBk, btnPorts ]),
			tips
		]);

		/* ---------- 软件版本 ---------- */
		/* 只读展示，数据来自后端 meshctl status 的 fwver / plugin_ver 字段。
		   分两行：插件版本（本包自身）+ 固件版本（宿主 OpenWrt 发行版描述）。
		   plugin_ver 取 /usr/libexec/mesh/version，比包数据库更可信（见后端注释）。 */
		function verRow(label, value) {
			return E('div', { 'class': 'mesh-ver-row' }, [
				E('span', { 'class': 'mesh-ver-label' }, label),
				E('span', { 'class': 'mesh-ver-value' }, value || _('未知'))
			]);
		}

		var verSec = section(_('软件版本'), [
			E('div', { 'class': 'mesh-ver-box' }, [
				verRow(_('插件版本'), d.plugin_ver),
				verRow(_('固件版本'), d.fwver)
			])
		]);

		/* ---------- 日志 ---------- */
		var logBox = E('pre', { 'class': 'mesh-log', 'id': 'mesh-log-box' }, _('加载中…'));
		var chkSyslog = E('input', { type: 'checkbox' });
		chkSyslog.addEventListener('change', loadLog);

		/* ★ 永远写"当前页面上"的那个日志框。
		   本页面 15 秒轮询重渲染一次，render() 每次都会新建一个 pre；
		   直接用闭包里的 logBox，异步返回时很可能写进一个已经被替换掉、
		   不再属于文档的节点 —— 表现就是"接口明明有返回，页面却没变化"。
		   所以这里按 id 重新查，并取最后一个（= 最新一次渲染的）。 */
		function logBoxEl() {
			var all = document.querySelectorAll('#mesh-log-box');
			return (all && all.length) ? all[all.length - 1] : logBox;
		}

		function setLog(txt) {
			logBoxEl().textContent = txt;
		}

		function loadLog() {
			setLog(_('加载中…'));
			var arg = chkSyslog.checked ? '200 --syslog' : '200';
			return runCmdArg('log', arg).then(function (r) {
				if (!r.ok) {
					console.error('[mesh] 读取日志失败:', r.err);
					setLog(_('读取日志失败：%s').format(r.err));
					return;
				}
				var t = String(r.text || '').replace(/\s+$/, '');
				if (t) {
					setLog(t);
					return;
				}
				console.warn('[mesh] 日志为空，后端返回:', r);
				setLog(_('（日志为空或文件不存在：/tmp/mesh/mesh.log）'));
			});
		}

		var btnLogRefresh = E('button', { 'class': 'btn' }, _('刷新'));
		btnLogRefresh.addEventListener('click', loadLog);

		var btnLogCopy = E('button', { 'class': 'btn' }, _('复制'));
		btnLogCopy.addEventListener('click', function () {
			var ta = E('textarea', { style: 'position:absolute;left:-9999px' });
			ta.value = logBoxEl().textContent;
			document.body.appendChild(ta);
			ta.select();
			var ok = false;
			try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
			document.body.removeChild(ta);
			ui.addNotification(null, E('p', {}, ok ? _('日志已复制到剪贴板') : _('复制失败，请手动选中后复制')),
				ok ? 'success' : 'warning');
		});

		var btnLogDownload = E('button', { 'class': 'btn' }, _('下载'));
		btnLogDownload.addEventListener('click', function () {
			var blob = new Blob([logBoxEl().textContent], { type: 'text/plain;charset=utf-8' });
			var url = URL.createObjectURL(blob);
			var a = E('a', { href: url, download: 'mesh-log.txt' });
			document.body.appendChild(a);
			a.click();
			document.body.removeChild(a);
			setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
		});

		var logSec = section(_('日志'), [
			E('div', { 'class': 'mesh-btnrow' }, [
				btnLogRefresh, btnLogCopy, btnLogDownload,
				E('label', { 'class': 'mesh-inline' }, [ chkSyslog, ' ' + _('包含系统日志(logread)') ])
			]),
			logBox,
			E('div', { 'class': 'mesh-muted' }, [
				E('div', {}, '· ' + _('日志存放在内存 /tmp/mesh/mesh.log，重启后清空；超过 600 行会自动保留最近 300 行。')),
				E('div', {}, '· ' + _('勾选「包含系统日志」会附上 logread 里与本插件相关的记录，可看到更早的内容。'))
			])
		]);

		loadLog();

		return E('div', {}, [
			section(_('能力检测'), capBox),
			section(_('射频能力'), radiosTable(d)),
			maintSec,
			verSec,
			logSec
		]);
	}
});
