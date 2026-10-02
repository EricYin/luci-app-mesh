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
	expect: { stdout: '' }
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

function runCmd(cmd) {
	return callMeshExec(cmd).then(function (res) {
		return (res && res.stdout) ? res.stdout : '';
	}, function (e) {
		ui.addNotification(null, E('p', {}, _('操作失败：%s').format(e)), 'danger');
		return null;
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

		/* 维护 */
		var btnRevert = E('button', { 'class': 'btn cbi-button-negative' }, _('还原组网前配置'));
		btnRevert.addEventListener('click', function () {
			if (!confirm(_('确定要还原到组网前的配置吗？路由器将重启，管理地址可能变化。'))) return;
			runCmd('revert').then(function (text) {
				ui.addNotification(null, E('p', {}, text || _('已还原组网前配置，路由器即将重启')), 'success');
			});
		});

		var btnPorts = E('button', { 'class': 'btn' }, _('端口并入内网(手动)'));
		btnPorts.addEventListener('click', function () {
			runCmd('port_bridging').then(function (text) {
				ui.addNotification(null, E('p', {}, text || _('端口并入操作已执行')), 'success');
			});
		});

		var tips = E('div', { 'class': 'mesh-muted' }, [
			E('div', {}, '· ' + _('首次应用配置时会自动把 wireless / network / dhcp / firewall 备份到 /etc/mesh-backup。')),
			E('div', {}, '· ' + _('「还原组网前配置」会恢复该备份，适合组网失败或想回到普通路由模式时使用。')),
			E('div', {}, '· ' + _('「端口并入内网」把所有物理端口(WAN/LAN)加入 br-lan，子节点应用配置时也会自动执行。'))
		]);

		var maintSec = section(_('维护'), [
			E('div', { 'class': 'mesh-btnrow' }, [ btnRevert, btnPorts ]),
			tips
		]);

		return E('div', {}, [
			section(_('射频能力'), radiosTable(d)),
			maintSec
		]);
	}
});
