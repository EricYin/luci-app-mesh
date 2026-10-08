'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';

var callMeshExec = rpc.declare({
	object: 'mesh',
	method: 'exec',
	params: [ 'cmd' ],
	/* ★ expect resolves ret = ret[firstKey] (see tools.js): {stdout:''} would
	   hand back the raw string and res.stdout would be undefined — which made
	   the "last apply result" block hide itself forever (parsed as code=2). */
	expect: { }
});

var callMeshStatus = rpc.declare({
	object: 'mesh',
	method: 'status',
	expect: { }
});

var m;

/* 关键项兜底落盘 —— 修 2026-10-02 真机 bug（根因比想象的深，务必看完）
 *
 * 现象：用户在设置页改完点保存，UCI 里反而**少掉** role / encryption / country /
 * band 四个键，meshctl apply 在 [1/7] 报"未设置本节点角色"。
 *
 * 真正的机制不是"没写进去"，而是 **LuCI 主动把它们删了**。form.js 的
 * AbstractValue.parse()：
 *     if (fval == null || fval == ''
 *         || (fval == this.default && (this.optional || this.rmempty))) {
 *             if (this.rmempty || this.optional) return this.remove(section_id);
 *             ...
 *     } else if (this.forcewrite || !isEqual(cval, fval)) {
 *             return this.write(section_id, fval);
 *     }
 * —— 只要下拉框停在 default 上、且 rmempty 为真（LuCI 的默认值就是真），保存时
 *   走的是 remove() → uci.unset() → 向 rpcd 提交一条**删除**。用户"没动过它"
 *   反而被抹掉出厂默认值；手改过的项（fval != default）走 write() 才留下来。
 *   这正好解释现场配置文件的古怪之处：enabled / mesh_id / channel / mesh_key
 *   （都改过）在，role / encryption / country / band / master_addr（没动过或为空）全没了。
 *
 * 对策两层，缺一不可：
 *   ① 治本：给这四个 ListValue 显式 o.rmempty = false（见下方表单定义）。
 *      rmempty 为假时不再走 remove 分支，转为 "cval != fval → write"，
 *      值缺失(cval=null) 就会被正常写入；值已存在且未改动则不动。
 *   ② 兜底：ensureKeyOptions() 补写空值项。但**调用时机是成败关键** ——
 *      必须在 m.save() 的回调里执行：
 *          save(cb, silent) { return this.parse().then(cb)
 *                                       .then(this.data.save.bind(this.data)) }
 *      即 parse() 之后、真正发起 uci 保存之前。放在 m.save() **之前**（第一版
 *      补丁就是这么写的）会被随后的 parse() 里的 remove()/unset() 直接取消，
 *      实测无效。放进去之后，uci.set 会顺带清掉 parse 留下的待删除项。
 */
var MESH_KEY_FALLBACK = { role: 'master', encryption: 'sae', country: 'CN', band: '5g' };

function optionDefault(k) {
	var secs = m.children || [];
	for (var i = 0; i < secs.length; i++) {
		var opts = secs[i].children || [];
		for (var j = 0; j < opts.length; j++) {
			if (opts[j].option === k && opts[j].default != null) {
				return opts[j].default;
			}
		}
	}
	return MESH_KEY_FALLBACK[k];
}

function ensureKeyOptions() {
	['role', 'encryption', 'country', 'band'].forEach(function (k) {
		var v = uci.get('mesh', 'main', k);
		if (v != null && v !== '') { return; }
		uci.set('mesh', 'main', k, optionDefault(k));
	});
}

/* 「上次应用结果」显示区 —— apply 走后台且固定返回 code=0（因为子节点会改 IP +
   network restart，应答发不回来），真实成败只能事后回读。 */
var lastApplyBox = null;

var callMeshLastApply = rpc.declare({
	object: 'mesh',
	method: 'exec',
	params: [ 'cmd' ],
	expect: { }   /* see callMeshExec: {} = full {code,stdout} object */
});

/* 解析 last_apply 的 "key=value" 多行输出 */
function parseLastApply(out) {
	var r = { code: 2, time: '', msg: '' };
	String(out || '').split('\n').forEach(function (line) {
		var i = line.indexOf('=');
		if (i < 1) { return; }
		var k = line.slice(0, i), v = line.slice(i + 1);
		if (k === 'code') { r.code = parseInt(v, 10); }
		else if (k === 'time') { r.time = v; }
		else if (k === 'msg') { r.msg = v; }
	});
	if (isNaN(r.code)) { r.code = 2; }
	return r;
}

function paintLastApply(box, r) {
	if (r.code === 2) {
		/* 无记录（含重启后清空）—— 整个区块不显示，避免展示过时/无关信息 */
		box.style.display = 'none';
		box.textContent = '';
		return r.code;
	}
	box.style.display = '';
	var ok = (r.code === 0);
	box.style.background = ok ? '#e8f5e9' : '#ffebee';
	box.style.color = ok ? '#1b5e20' : '#b71c1c';
	box.textContent = _(ok ? '上次应用：成功' : '上次应用：失败')
		+ (r.time ? '（' + r.time + '）' : '')
		+ (r.msg ? ' —— ' + r.msg : '');
	return r.code;
}

function fetchLastApply(box) {
	return callMeshLastApply('last_apply').then(function (res) {
		paintLastApply(box, parseLastApply(res && res.stdout));
	}, function () {
		/* 拉不到（例如子节点正在换 IP）就保持原样，不打扰用户 */
	});
}

function applyLater(msg) {
	return callMeshExec('apply').then(function (res) {
		var out = (res && res.stdout) ? res.stdout : '';
		ui.addNotification(null, E('p', {}, msg || out || _('已触发应用')), 'success');
		/* 后台跑完再回读真实结果：8 秒一次（校验类失败此时已落盘），
		   累计 22 秒再补一次（覆盖无线重启）。拉不到就静默放弃 ——
		   子节点换 IP 期间连接必然断，刷新页面时仍能看到上次结果。 */
		var notified = false;
		[8000, 14000].forEach(function (delay) {
			setTimeout(function () {
				callMeshLastApply('last_apply').then(function (r) {
					var p = parseLastApply(r && r.stdout);
					if (lastApplyBox) { paintLastApply(lastApplyBox, p); }
					if (p.code === 1 && !notified) {
						notified = true;
						ui.addNotification(null, E('p', {}, _('应用失败：%s').format(p.msg || '')), 'danger');
					}
				}, function () {});
			}, delay);
		});
	}, function (e) {
		ui.addNotification(null, E('p', {}, _('应用失败：%s').format(e)), 'danger');
	});
}

return view.extend({
	load: function () {
		return callMeshStatus();
	},

	render: function (status) {
		var s, o;
		status = status || {};

		m = new form.Map('mesh', _('Mesh 组网设置'),
			_('802.11s 无线 Mesh 组网。主节点作为上网网关（WAN 上行）并作为配置源；子节点自动跟随主节点的无线设置，全部物理端口并入内网。'));

		/* ================= 一步组网 ================= */
		s = m.section(form.NamedSection, 'main', 'main', _('一步组网'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用 Mesh 组网'));
		o.rmempty = false;
		o.default = o.disabled;

	o = s.option(form.ListValue, 'role', _('本节点角色'));
	o.value('master', _('主节点(上网网关 · 配置源)'));
	o.value('client', _('子节点(全端口内网 · 跟随主节点)'));
	o.default = 'master';
	/* rmempty=false 是必须的，不是可选项 —— 见文件头 ensureKeyOptions 的说明：
	   rmempty 为真时，只要下拉框停在 default 上，LuCI 保存时会把这个键从 UCI
	   里**删除**，等于用户"什么都没改"却被抹掉了出厂默认值。 */
	o.rmempty = false;
		o.description = _('主节点：作为上网网关（WAN 上行）并作为配置源，终端 Wi-Fi 在「网络 → 无线」里设置；'
			+ '子节点：自动采用主节点的无线设置（SSID/密码/802.11r），每 10 秒核对一次，'
			+ '全部物理端口(WAN/LAN)都将并入内网 br-lan，并关闭本机 DHCP 服务。');

		o = s.option(form.Value, 'mesh_id', _('Mesh 名称 (Mesh ID)'));
		o.placeholder = 'XxMesh-143D90';
		o.datatype = 'maxlength(32)';
		o.description = _('同一网络内所有节点必须一致，最长 32 字符。主节点留空时按本机 MAC 自动生成（XxMesh-后 6 位），生成一次后长期固定；这样不会和邻居的同款固件重名。');

		o = s.option(form.Value, 'mesh_key', _('Mesh 回程密码'));
		o.password = true;
		o.datatype = 'minlength(8)';
		o.placeholder = _('至少 8 位');
		o.rmempty = false;
		o.description = _('至少 8 位，使用 WPA3-SAE 加密，所有节点必须一致。子节点还用它作为同步令牌。主节点留空时自动生成 16 位随机密码。可以自己改，但改完所有节点都要一致。');

	/* 回程密码的三个小工具：随机生成 / 明文切换 / 复制。
	   原来只有一个 password 框，看不见也复制不了，手工添加节点时很不方便。
	   这里不写 UCI（DummyValue），只操作上面那个输入框的 DOM。

	   ★ 真机踩坑（2026-10-05）：按钮能显示、点了却完全没反应、控制台也没有请求。
	     根因是 LuCI 的密码框是**两层结构**（ui.js 的 UITextfield）：
	         外层 <div id="cbid.mesh.main.mesh_key">          ← 容器
	         里面 <input id="widget.cbid.mesh.main.mesh_key">  ← 真正的输入框
	     而 form.js 里 renderFrame() 用的正是外层那个 id。于是
	     getElementById('cbid.mesh.main.mesh_key') 拿到的是**div**，
	     给它赋 .value / .type 不会有任何可见变化 —— 表现就是"点了没反应"。
	     查找顺序必须是：widget. 前缀的 input → 外层容器里的 input → 按 class 兜底。 */
	o = s.option(form.DummyValue, '_key_tools', _('密码工具'));
	o.render = function () {
		var findInput = function () {
			var el = document.getElementById('widget.cbid.mesh.main.mesh_key');
			if (el && el.tagName === 'INPUT') return el;
			var frame = document.getElementById('cbid.mesh.main.mesh_key');
			if (frame) {
				el = frame.querySelector('input');
				if (el) return el;
			}
			return document.querySelector('input.cbi-input-password') ||
				document.querySelector('input[id$="mesh_key"]');
		};
		var randKey = function (n) {
			var cs = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
			var a = new Uint8Array(n), s = '', i;
			if (window.crypto && window.crypto.getRandomValues) {
				window.crypto.getRandomValues(a);
			} else {
				for (i = 0; i < n; i++) a[i] = Math.floor(Math.random() * 256);
			}
			for (i = 0; i < n; i++) s += cs.charAt(a[i] % cs.length);
			return s;
		};

		/* type="button" 必须显式写：button 在 <form> 里默认是 submit，
		   不写就会触发 LuCI 的保存动作（用户看到的就是"点了没反应还弹保存"）。 */
		var btnGen = E('button', { 'class': 'cbi-button cbi-button-apply', 'type': 'button' }, _('随机生成'));
		btnGen.addEventListener('click', function (ev) {
			ev.preventDefault();
			ev.stopPropagation();
			var inp = findInput();
			if (!inp) { ui.addNotification(null, E('p', {}, _('未找到密码输入框，请刷新页面（Ctrl+F5）后重试')), 'warning'); return; }
			inp.type = 'text';
			inp.value = randKey(16);
			btnShow.textContent = _('隐藏');
			/* 让 LuCI 感知到值变了，否则保存时可能按"未改动"处理 */
			inp.dispatchEvent(new Event('change', { bubbles: true }));
		});

		var btnShow = E('button', { 'class': 'cbi-button cbi-button-neutral', 'type': 'button' }, _('显示'));
		btnShow.addEventListener('click', function (ev) {
			ev.preventDefault();
			ev.stopPropagation();
			var inp = findInput();
			if (!inp) { ui.addNotification(null, E('p', {}, _('未找到密码输入框，请刷新页面（Ctrl+F5）后重试')), 'warning'); return; }
			inp.type = (inp.type === 'password') ? 'text' : 'password';
			btnShow.textContent = (inp.type === 'password') ? _('显示') : _('隐藏');
		});

		var btnCopy = E('button', { 'class': 'cbi-button cbi-button-neutral', 'type': 'button' }, _('复制'));
		btnCopy.addEventListener('click', function (ev) {
			ev.preventDefault();
			ev.stopPropagation();
			var inp = findInput();
			if (!inp) { ui.addNotification(null, E('p', {}, _('未找到密码输入框，请刷新页面（Ctrl+F5）后重试')), 'warning'); return; }
			if (navigator.clipboard && navigator.clipboard.writeText) {
				navigator.clipboard.writeText(inp.value);
			} else {
				inp.select();
				document.execCommand('copy');
			}
			btnCopy.textContent = _('已复制');
			setTimeout(function () { btnCopy.textContent = _('复制'); }, 1500);
		});

		/* 自己拼出 cbi-value / cbi-value-title / cbi-value-field 这三层：
		   直接返回一个裸 div 会丢掉 LuCI 的行容器，和上下几行对不齐。 */
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('密码工具')),
			E('div', { 'class': 'cbi-value-field' }, [ btnGen, ' ', btnShow, ' ', btnCopy ])
		]);
	};

		o = s.option(form.ListValue, 'encryption', _('Mesh 回程加密'));
		o.value('sae', _('WPA3-SAE(推荐, 802.11s 强制要求)'));
		o.value('sae-mixed', _('WPA3/WPA2 混合(兼容老旧节点)'));
	o.value('none', _('不加密(不建议)'));
	o.default = 'sae';
	o.rmempty = false;   // 同 role：停在默认值时不得被 LuCI 删掉
	o.description = _('路由器之间互联所用的加密方式，所有节点必须一致。');

		o = s.option(form.ListValue, 'band', _('回程频段'));
		// 按本机实际射频能力列出频段：从后端 status.channels 取（缺省回退固定列表）
		var meshBands = {};
		if (status.channels) {
			['5g', '2g', '6g'].forEach(function (b) {
				if (Array.isArray(status.channels[b]) && status.channels[b].length) {
					meshBands[b] = status.channels[b];
				}
			});
		}
		if (!Object.keys(meshBands).length) {
			// 旧固件后端未提供 channels 时回退
			meshBands = { '5g': [36, 40, 44, 48,149, 153, 157, 161], '2g': [1, 6, 11] };
		}
		if (meshBands['5g']) { o.value('5g', _('5 GHz(推荐)')); }
		if (meshBands['2g']) { o.value('2g', _('2.4 GHz(穿墙好)')); }
		if (meshBands['6g']) { o.value('6g', _('6 GHz(Wi-Fi 6E)')); }
	o.value('auto', _('自动选择'));
	o.default = meshBands['5g'] ? '5g' : (meshBands['2g'] ? '2g' : (meshBands['6g'] ? '6g' : 'auto'));
	o.rmempty = false;   // 同 role：停在默认值时不得被 LuCI 删掉
		o.description = _('路由器之间互联所用的频段，按本机实际射频能力列出。'
			+ '5GHz 干扰少、速率高；2.4GHz 穿墙好、覆盖远；本机没有的频段不会出现。');

		// 回程信道：随所选频段联动。拆成 channel_5g/2g/6g/auto 四个选项，各自
		// depends('band', …) 让 LuCI 在频段变化时自动显隐并重渲染；它们都映射到
		// 同一个 UCI 项 channel（ucioption），仅在对应频段下可见、隐藏时不删值。
		var chanDesc = _('同一组网内所有节点必须使用完全相同的一个信道。'
			+ '802.11s 回程不像手机连 WiFi 那样自动跟随对端信道：两端射频落在不同信道上，'
			+ '就永远收不到对方信标，会出现"两个接口都 up、却始终 0 个对端"。'
			+ '默认 36（5GHz 非 DFS 段首个信道，无需等待雷达检测，支持面最广）；'
			+ '40/44/48/149/153/157/161 同样可用，关键是两端填一样的。'
			+ '主节点选「自动」时，子节点必须先经其它路径（如网线）连上它才能跟随其实际信道，'
			+ '所以不建议用自动。'
			+ '另外：本频段的 AP 与回程共用同一射频，改这里也会把本频段 AP 的信道一起改掉；'
			+ '主节点为固定信道时，子节点另一频段的 AP 会按节点序号自动错开，互不干扰。');
		function addChannelOpt(bandVal, labelPrefix, chans) {
			var co = s.option(form.ListValue, 'channel_' + bandVal, _('回程信道'));
			co.depends('band', bandVal);
			co.ucioption = 'channel';   // 四个选项共用同一 UCI 项
			co.retain = true;           // 频段不符时隐藏，但不删除 channel 值
			co.rmempty = false;
			(chans || []).forEach(function (c) { co.value(String(c), labelPrefix + c); });
			co.value('auto', _('自动（仅在主节点上有意义，子节点会被改为默认信道）'));
			co.default = (bandVal === 'auto') ? 'auto' : (chans && chans[0] ? String(chans[0]) : 'auto');
			co.description = chanDesc;
			return co;
		}
		addChannelOpt('5g', '5 GHz — ', meshBands['5g']);
		addChannelOpt('2g', '2.4 GHz — ', meshBands['2g']);
		addChannelOpt('6g', '6 GHz — ', meshBands['6g']);
		addChannelOpt('auto', '', null);  // 频段=auto 时信道只能 auto

		o = s.option(form.ListValue, 'country', _('国家/地区代码'));
		o.value('CN', _('中国'));
		o.value('US', _('美国'));
		o.value('JP', _('日本'));
		o.value('DE', _('德国'));
	o.value('00', _('全球(宽松)'));
	o.default = 'CN';
	o.rmempty = false;   // 同 role：停在默认值时不得被 LuCI 删掉
	o.description = _('影响可用信道与发射功率。');

		o = s.option(form.Value, 'master_addr', _('主节点地址(子节点)'));
		o.placeholder = '192.168.1.1';
		o.datatype = 'host';
		o.depends('role', 'client');
		o.description = _('一般留空即可：子节点的内网地址由主节点 DHCP 分发，它的默认网关就是主节点，'
			+ '后端会自动取用。只有子节点不在主节点网段（或 DHCP 还没完成就要拉配置）时才需要填。'
			+ '留空且解析结果恰好是本机地址时，后端会直接给出提示，不会静默失败。');

		/* ================= 子节点本机地址：固定 DHCP，不提供选项 ================= */
		// 子节点会关闭自身 DHCP 服务，它的内网地址与下挂终端地址一律由主节点分发。
		// 历史上这里还有个「保留原有静态地址」选项，已删除 —— 它能造出一个致命状态：
		// `proto=static` 而 `ipaddr` 为空 → br-lan 一个地址都没有 → 节点彻底失联，
		// 只能靠 IPv6 链路本地地址去救（真机踩到过）。恒为 DHCP 从根上消除该状态。
		// 旧配置里残留的 client_addr 选项由 meshctl apply 自动清掉。
		// br-lan 的 MAC 由 apply 钉成设备主 MAC：网桥 MAC 会随端口就绪顺序漂移，
		// 一漂 DHCP 租约就换地址，子节点地址反而不可追踪。

		/* ================= 路径选择 (batman-adv) —— 强制项，界面上不提供开关 ================= */
		// batman-adv 已随本包编译依赖强制安装（kmod-batman-adv + batctl），所以恒为启用：
		//   · 路径选择：由 batman-adv 按 TQ 统一择优（802.11s 只负责建立链路）
		//   · 网关模式：当前恒为 off（方案 A）—— 本插件是单主节点 + br-lan 二层桥接，
		//     全网没有出网网关，client/server 都会让 DHCP 请求被 batman 单播投给
		//     "选中的网关"而整包丢弃。off 让请求回到广播泛洪。
		//     后期"多网关开关"（方案 C）上线后再按角色自动判断。
		//   · 有线回程：固定 B 方案 —— 端口与 bat0 同进 br-lan，有网线时网桥二层直转
		//     （零 batman 封装开销、满线速），拔线后 bat0 直接接管无线回程（它一直是
		//     forwarding；跨 mesh 的环由 BLA 负责，bat0 并不会被 STP 阻塞）
		//   · 网关通告带宽：仅在网关模式为 server 时写入（当前 off，故不写）
		// 以上均由 meshctl apply 强制写回 UCI，无需（也不允许）用户设置，故不再渲染任何选项。
		// 802.11s 自身的二层转发 / 网关通告 / HWMP 根模式在 batman-adv 接管后必然让位，
		// 同样不暴露给用户（UCI 里仍保留，仅用于旧配置兼容与状态展示）。

		/* ================= 一键加入（配对） ================= */
		// 这里的四项都属于"新节点入网的临时通道"，与主网络的 Mesh ID / 回程密码
		// 是两回事（那两把钥匙在上面）。绝大多数人**不需要动这里**：同固件设备
		// 出厂就带同一套配对凭证，改了反而要全网跟着改，否则新节点连不上配对信号。
		s = m.section(form.NamedSection, 'main', 'main', _('一键加入（配对）'));
		s.addremove = false;

		o = s.option(form.Value, 'pair_window', _('加入窗口时长(秒)'));
		o.placeholder = '600';
		o.datatype = 'range(0,86400)';
		o.description = _('主节点点「开放加入」后，配对信号自动撤掉前的秒数，默认 600（10 分钟）；0 = 常开。'
			+ '网页上开窗时可以临时选别的时长，不必改这里。窗口期内任何"连得上本节点、'
			+ '知道固件固定配对密码"的设备都能领到凭证，所以默认只开几分钟。');

		o = s.option(form.Value, 'pair_wait', _('子节点最长等待(秒)'));
		o.placeholder = '300';
		o.datatype = 'range(30,3600)';
		o.description = _('子节点点「加入」后，等待主节点开窗的最长时间，默认 300（5 分钟）。'
			+ '给得宽是刻意的：通常是先在子节点上按、再走去开主节点的窗，顺序不该成为负担。');

		o = s.option(form.Value, 'pair_ssid', _('配对信号名称 (SSID)'));
		o.placeholder = 'XxMesh-Pair';
		o.datatype = 'maxlength(32)';
		o.description = _('新节点临时连入用的信号名。与回程用的 Mesh ID 无关，最长 32 字符。');

		o = s.option(form.Value, 'pair_key', _('配对密码'));
		o.password = true;
		o.placeholder = 'xxmesh-pair';
		o.datatype = 'minlength(8)';
		o.description = _('配对信号的密码，至少 8 位。它**不是**回程密码，公开也无妨 ——'
			+ '窗口关闭时配对信号根本不存在，这串密码只在开窗的那几分钟里有意义。'
			+ '一般不用改；真要改，全网所有节点必须改成同一个值。');

		o = s.option(form.Flag, 'pair_hidden', _('隐藏配对信号（不广播 SSID）'));
		o.default = '1';
		o.description = _('开启后配对信号不出现在 WiFi 列表里，新节点靠定向扫描照样能找到并加入；'
			+ '附近设备则看不到它，减少被好奇尝试。关掉则恢复成普通广播信号。'
			+ '两端不必一致：主节点开窗的那份按本机设置走，子节点镜像出去的配对信号按子节点自己的设置走。');

		/* ================= 按键组网（WPS 键时长分档） ================= */
		// 一个键按"按住几秒"分档 —— 出厂机开箱直接按，不用先进网页选角色：
		// 谁开窗谁是主节点、谁加入谁是子节点，按键顺带把角色写对。
		// 装上本包后系统自带的 WPS 会被这三档完全覆盖（/etc/rc.wps/10-mesh 返回 0 即 break）。
		s = m.section(form.NamedSection, 'main', 'main', _('按键组网（WPS 键）'));
		s.addremove = false;

		o = s.option(form.Flag, 'button', _('允许按键组网'));
		o.default = '1';
		o.description = _('关掉后 WPS 键恢复成系统自带行为（手机免密连入 / 本机连别人的 WiFi），本插件完全不介入。');

		o = s.option(form.Value, 'btn_join_max', _('加入档：按住不超过 (秒)'));
		o.placeholder = '4';
		o.datatype = 'range(1,30)';
		o.description = _('在这个秒数内松手 = 加入网络：设为子节点并启用，然后自动领凭证并应用。'
			+ '已是子节点时按一下是重新同步（主节点改了 Mesh ID 或密码后，按一下就跟上）。'
			+ '正在跑的主节点按这一档会被拒绝并闪红灯。');

		o = s.option(form.Value, 'btn_open_min', _('开窗档：起始秒'));
		o.placeholder = '5';
		o.datatype = 'range(2,60)';
		o.description = _('按住到这个秒数起 = 开放加入：设为主节点并启用，从未应用过时会自动应用一次，'
			+ '然后开窗；窗口已经开着时再按一次是立即关窗。已在网的子节点按这一档会被拒绝。');

		o = s.option(form.Value, 'btn_open_max', _('开窗档：结束秒'));
		o.placeholder = '9';
		o.datatype = 'range(2,60)';

		o = s.option(form.Value, 'btn_exit_min', _('退出档：起始秒'));
		o.placeholder = '14';
		o.datatype = 'range(3,120)';
		o.description = _('按住到这个秒数起 = 退出组网（还原组网前配置并重启）。本档位与开窗档之间'
			+ '刻意留一段空档：人手按不准整数秒，从"想开窗"滑到"退出组网"的代价太大。'
			+ '松手后还有一段反悔时间（见下），期间再按一次键即可取消。');

		o = s.option(form.Value, 'btn_exit_max', _('退出档：结束秒'));
		o.placeholder = '20';
		o.datatype = 'range(3,120)';
		o.description = _('超过这个秒数视为误压或卡键，什么都不做。');

		o = s.option(form.Value, 'btn_exit_grace', _('退出反悔时间(秒)'));
		o.placeholder = '10';
		o.datatype = 'range(0,120)';
		o.description = _('退出档松手后，先闪红灯这么久再真正执行，期间再按一次 WPS 键即取消。'
			+ '退出组网会还原配置并重启路由器，留这个窗口是为了让误按有救回来的机会。');

		o = s.option(form.Value, 'button_led', _('反馈指示灯'));
		o.placeholder = _('留空 = 自动');
		o.description = _('按键反馈用哪盏灯，填 /sys/class/leds 下的名字（如 blue:phone）。'
			+ '留空 = 自动挑选：优先 phone，其次 wlan，最后 power；被拒绝或退出前的反悔期用红灯。'
			+ '动作结束后会自动还原这盏灯原来的状态。');

		/* ================= 链路控制 ================= */
		// 这两项决定"无线链路能否建立"；链路建立之后多跳路径的优劣由 batman-adv
		// 按 TQ(传输质量)自动判定，所以这里不提供任何选路相关的开关。
		// 留空时后端分别按 -80 dBm / 8 个邻居处理（mesh_default_rssi / mesh_default_max_peers）。
		s = m.section(form.NamedSection, 'main', 'main', _('链路控制'));
		s.addremove = false;

		o = s.option(form.Value, 'rssi', _('RSSI 接入门限 (dBm)'));
		o.placeholder = '-80';
		o.datatype = 'range(-100,-40)';
		o.description = _('信号弱于此值的邻居不会建立链路。范围 -100 ~ -40，越小越容易连上但质量越差。'
			+ '链路建立之后，多跳路径的优劣由 batman-adv 按 TQ(传输质量)自动判定。');

		o = s.option(form.Value, 'max_peers', _('最大邻居数'));
		o.placeholder = '8';
		o.datatype = 'range(1,32)';
		o.description = _('单个射频最多同时连接的邻居数量，1 ~ 32。');

		o = s.option(form.Value, 'peer_ttl', _('离线节点保留时长(秒)'));
		o.placeholder = '3600';
		o.datatype = 'range(60,604800)';
		o.description = _('子节点最后一次上报后，在节点列表里保留多久，默认 3600（1 小时）；'
			+ '最短 60 秒。留太久，早已拆走的节点会一直以「离线」挂在列表里；'
			+ '留太短，正在重启或升级的节点会被当成新节点重新排号（节点序号决定信道错开）。'
			+ '离线行会显示「最后上报 X 前」，据此判断它是刚掉线还是老记录。');

		/* 放在表单上方：apply 是后台执行且固定返回成功，这里补上"上一次到底成了没有" */
		var lastBox = E('div', {
			'style': 'display:none;margin:0 0 1em 0;padding:.6em .8em;border-radius:4px;'
				+ 'background:#f6f6f6;color:#666;font-size:90%'
		});
		lastApplyBox = lastBox;
		fetchLastApply(lastBox);

		/* 坑（实测 2026-09-24，主节点 LuCI 27）：**m.render() 返回的是 Promise**
		   （LuCI 的 form.Map 异步渲染），不能像普通 DOM 节点那样直接放进 E()
		   的子节点数组 —— 那样会被当成文本渲染成 "[object Promise]"，整个表单消失、
		   页面只剩一行 [object Promise]。
		   改法：先 Promise.resolve 拿到真实节点，再和「上次应用」区块一起组装。 */
		return Promise.resolve(m.render()).then(function (node) {
			return E('div', {}, [ lastBox, node ]);
		});
	},

	/* 保存后额外触发一次 meshctl apply
	   注意 ensureKeyOptions 是作为 m.save() 的**回调**传入的（不是提前调用）：
	   m.save(cb) 的执行顺序是 parse() → cb → uci.save()，放在 cb 里才能盖住
	   parse() 对默认值的 remove()。详见文件头注释。 */
	handleSave: function () {
		return m.save(ensureKeyOptions);
	},

	/* 「保存并应用」= 三步，顺序绝不能颠倒：
	 *
	 *   ① m.save()   —— 把表单值交给 rpcd 暂存
	 *   ② uci.apply() —— **落盘**。这是最容易漏的一步，也是本页历史 bug 的根因。
	 *   ③ meshctl apply —— 读落盘后的配置，真正建 mesh0/bat0
	 *
	 * 关于 ②：rpcd 的 uci.set 暂存**只存在于会话内存里**，shell 完全看不到
	 * （实测：web 侧 uci.set 后，设备上 `uci changes mesh` 为空、
	 * /tmp/.uci/mesh 为 0 字节）。而 meshctl 是独立进程、读的是 /etc/config
	 * 里**已落盘**的值 —— 漏掉 ② 就等于让后端拿旧值干活：enabled 明明设成 1，
	 * apply 却读到 0，走进「停用」分支把接口拆掉。真机踩到过（2026-09-23）。
	 *
	 * 为什么是 uci.apply() 而不是 uci.commit()：这个版本的 rpcd 对 uci.commit
	 * 直接返回 Access denied，uci.js 里也只声明了 apply（没有 commit）。
	 * uci.apply() 自带 10 秒回滚保护：它会先 commit+reload，再轮询 confirm，
	 * 失败则自动回滚，不会留下半截配置。
	 * 这一步同时也是 LuCI 内置 handleSaveApply 的行为（ui.changes.apply），
	 * 本页因为要额外跑 meshctl apply 才覆盖了它，所以必须自己补回来。
	 *
	 * 坑：没有待提交改动时 rpcd 的 uci.apply 返回 **5**（NO_DATA「未收到数据」），
	 * uci.js 会把它当失败 reject 掉（实测 2026-09-23）。 reject 出来的**有两种形态**：
	 *   · 数字 5 —— 部分固件的 uci.js 直接把 ubus 状态码抛出来；
	 *   · RPCError 对象 —— 另一些固件（重装后的 LuCI，实测同日）包成对象，
	 *     message 形如 "RPC call to uci/apply failed with ubus code 5: 未收到数据"。
	 * 只判 `rv === 5` 时后者会漏：误报"保存失败"、后面的 meshctl apply 也不跑了
	 * —— 而用户点这个按钮往往正是想"按当前配置重新应用一遍"。所以两种形态都
	 * 识别为「无事可做」，继续走 meshctl apply。 */
	handleSaveApply: function () {
		function isNoData(rv) {
			if (rv === 5 || rv === '5') {
				return true;
			}
			if (rv && rv.code === 5) {
				return true;
			}
			if (rv && typeof rv.message === 'string') {
				return /ubus code 5\b/.test(rv.message) || rv.message.indexOf('未收到数据') !== -1;
			}
			return false;
		}
		/* 同 handleSave：兜底必须在 m.save() 的回调里跑，不能提前 */
		return m.save(ensureKeyOptions)
			.then(function () {
				return uci.apply().catch(function (rv) {
					if (isNoData(rv)) {
						return null;
					}
					return Promise.reject(rv);
				});
			})
			.then(function () {
				return applyLater();
			})
			.catch(function (e) {
				ui.addNotification(null, E('p', {}, _('保存失败：%s').format(e)), 'danger');
			});
	},

	handleReset: function () {
		return m.reset();
	}
});
