'use strict';
'require view';
'require rpc';
'require uci';
'require ui';

/* ============================================================================
 * WiFi 快速设置 —— 独立页面，与「网络 → 无线」共存（只是它的一个快捷入口）
 *
 * 定位：给普通用户的"填名字 / 选加密 / 选信道"的简单入口。它**不引入任何新的状态
 * 层**，就是 wireless 配置的另一个写入者 —— 组网的同步/镜像链路本来就在读 wireless
 * （AP 段的 ssid/enc/key、radio 的 channel/htmode），所以这里写进主节点的无线配置会
 * 自动顺着现有链路下发到子节点，不需要碰 mesh 的同步代码。
 *
 * 字段落点与同步关系：
 *   SSID / 加密 / 密码  -> AP 段      -> 下发子节点（mesh-sync 的 ap 数组）
 *   信道 / 通道宽度      -> radio 段   -> 下发子节点（radios 数组 + 按序号错开）
 *   国家/地区代码        -> radio 段   -> **仅本机 · 每节点各自设置**（mesh-sync 不下发 country）
 *   发射功率            -> radio 段   -> **仅本机 · 每节点各自设置**（插件从不写 txpower，
 *                                        不会被 apply 回滚，也不会被子节点同步覆盖）
 *
 * 组网联动（未组网时全部可改，就是一个普通 WiFi 页）：
 *   · 主节点：SSID/加密/带宽/国家码/发射功率可改（它就是同步源）；**回程频段的信道锁定为
 *     「跟随回程」** —— 回程频段与回程共用同一射频，改了会拆掉组网，故只读，要改请去
 *     「组网设置」。发射功率**不锁回程频段**（原生无线页本来就能改），只加一句提示。
 *   · 子节点：SSID/加密/信道/带宽只读 —— 这几项**都在同步链路上**（mesh-sync 下发，
 *     子节点每 10 秒镜像一次），在这里改会在下一轮被覆盖回去；**国家码与发射功率仍可改**
 *     —— 这两项**不参与同步**，是每台设备自己的设置（见上面「字段落点」）。
 *
 * 保存：uci.set -> uci.save() -> uci.apply()（落盘并触发无线重载）-> 组网时再调
 *   meshctl wifi_ensure 补一次自愈（防 mt76 热重载 -122 把 AP 留在 disabled）。
 *   ★ 必须 uci.save()：rpcd 的 uci.set 只在会话内存里，shell / meshctl 看不到；而
 *     luci/uci.js 的 apply() 只提交 rpcd 已暂存的内容，不会替你 save（见其源码）。
 * ========================================================================== */

var callMeshStatus = rpc.declare({ object: 'mesh', method: 'status', expect: {} });
var callMeshExec = rpc.declare({ object: 'mesh', method: 'exec', params: [ 'cmd' ], expect: {} });

/* 发射功率用的就是**原生无线页同一批** iwinfo 接口（txpowerlist / info）。
   ★★ 这两个都用 `params: ['device']` —— 这是**位置参数**形式（与原生页
   `callTxPowerList(section_id)` 一致）：调用时要传「射频段名字符串」本身，例如
   `callIwinfoInfo('radio0')`。若误传对象 `{device:'radio0'}`，LuCI 会拼成
   `{"device":{"device":"radio0"}}` → ubus 报 Invalid argument → Promise reject →
   页面**静默退化成只读标签**（真机踩过一次，务必保持位置传参）。 */
var callIwinfoTxPowerList = rpc.declare({ object: 'iwinfo', method: 'txpowerlist', params: [ 'device' ], expect: { results: [] } });
var callIwinfoInfo = rpc.declare({ object: 'iwinfo', method: 'info', params: [ 'device' ], expect: {} });

var ENC_OPTS = [
	{ v: 'psk2', t: 'WPA2-PSK' },
	{ v: 'psk', t: 'WPA-PSK' },
	{ v: 'sae', t: 'WPA3-SAE' },
	{ v: 'sae-mixed', t: 'WPA3 / WPA2 混合' },
	{ v: 'none', t: '不加密（开放）' }
];

var BAND_ORDER = [ '2g', '5g', '6g' ];

/* 国家/地区代码：**故意只列少量常用项**（与「组网设置」页同一份列表，避免两页选项不一致）。
   不引 iwinfo.countrylist（247 项）—— 对家用场景是纯噪音。要冷门国家请去「组网设置」或原生无线页。
   当前值若不在表内，countryField() 会把它补进来，保证已有配置不丢。 */
var COUNTRY_OPTS = [
	{ v: 'CN', t: '中国' },
	{ v: 'US', t: '美国' },
	{ v: 'JP', t: '日本' },
	{ v: 'DE', t: '德国' },
	{ v: 'AU', t: '澳大利亚' },
	{ v: '00', t: '全球（宽松）' }
];

function bandText(b) {
	return b === '2g' ? '2.4 GHz' : (b === '6g' ? '6 GHz' : '5 GHz');
}

/* htmode（HE160 / VHT80 / HT20 …）对普通用户是黑话，拆成两段人话：
   前缀 = 制式代际（HT=WiFi4 · VHT=WiFi5 · HE=WiFi6 · EHT=WiFi7），数字 = 带宽 MHz。
   注意顺序：EHT/VHT 要排在 HT 前面，否则 EHT20 会被 HT 规则吃掉。 */
var HTMODE_GEN = { HT: 4, VHT: 5, HE: 6, EHT: 7 };

function htmodeParse(v) {
	var m = /^(EHT|VHT|HE|HT)(\d+)$/.exec(v || '');
	if (!m) return null;
	return { gen: HTMODE_GEN[m[1]] || 0, mhz: parseInt(m[2], 10) };
}

function htmodeLabel(v) {
	if (!v) return _('默认（自动）');
	var m = htmodeParse(v);
	if (!m) return v;
	return m.mhz + ' MHz · WiFi ' + m.gen;
}

/* iwinfo 的列表类返回归一：`{results:[…]}` 与裸数组两种形态都认，拿不到就 null */
function normList(rv) {
	if (!rv) return null;
	if (Array.isArray(rv)) return rv;
	if (Array.isArray(rv.results)) return rv.results;
	return null;
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

function row(label, field) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, label),
		E('div', { 'class': 'cbi-value-field' }, [ field ])
	]);
}

function note(text, kind) {
	return E('div', { 'class': 'mesh-note' + (kind ? ' ' + kind : '') }, text);
}

/* rpcd 的 uci.apply 在"没有待提交改动"时返回 5（未收到数据），uci.js 会把它当失败
   reject。两种形态都要认：裸数字 5 / 带 message 的 RPCError 对象。 */
function isNoData(rv) {
	if (rv === 5 || rv === '5') return true;
	if (rv && rv.code === 5) return true;
	if (rv && typeof rv.message === 'string')
		return /ubus code 5\b/.test(rv.message) || rv.message.indexOf('未收到数据') !== -1;
	return false;
}
/* ---------- 漫游灵敏度（r57）常量 ----------
 * ★ 这里**只有档位编号与文案**，没有"档位 → dawn 参数"的映射表 ——
 *   那份映射留在后端一处（functions.sh 的 mesh_roam_level_params /
 *   mesh_roam_effective，经 meshctl roam_show 暴露）。前端只显示后端算好的
 *   生效值，所以改档位规则永远不用动 JS。 */
var ROAM_LEVELS = [
	{ v: '1',  t: '1 · 最稳（几乎不切）' },
	{ v: '2',  t: '2 · 很稳' },
	{ v: '3',  t: '3 · 稳' },
	{ v: '4',  t: '4 · 偏稳' },
	{ v: '5',  t: '5 · 标准（推荐）' },
	{ v: '6',  t: '6 · 略灵敏' },
	{ v: '7',  t: '7 · 灵敏' },
	{ v: '8',  t: '8 · 很灵敏' },
	{ v: '9',  t: '9 · 激进' },
	{ v: '10', t: '10 · 极激进（可能来回跳）' }
];

/* 踢人方法。默认锁 1（相对比较）—— 只有它"只在确实存在更优 AP 时才动作"，
 * 语义才等于"漫游灵敏度"。方法 2 在**没有更好 AP 时也会发 BTM 软踢**（官方
 * CONFIGURE.md 明说），设备白扫一遍；3 = 1+2 是 OpenWrt 打包默认值。 */
var ROAM_KICKING_OPTS = [
	{ v: '1', t: '1 · 相对比较（推荐）' },
	{ v: '0', t: '0 · 关闭（只观测不动作）' },
	{ v: '2', t: '2 · 绝对信号（无更好 AP 时也会软踢）' },
	{ v: '3', t: '3 · 两者（OpenWrt 出厂默认）' }
];

/* 高级覆盖项：k = UCI 选项名后缀（mesh.main.roam_<k>），t = 界面标签。
 * 留空 = 跟随档位（输入框以"生效值"作 placeholder）。 */
var ROAM_ADV = [
	{ k: 'kicking',      t: '踢人方法',           kind: 'select' },
	{ k: 'threshold',    t: '分数差阈值',         kind: 'num' },
	{ k: 'minkick',      t: '连续评估次数',       kind: 'num' },
	{ k: 'rssi_val',     t: '好信号门限 (dBm)',   kind: 'num' },
	{ k: 'low_rssi_val', t: '差信号门限 (dBm)',   kind: 'num' },
	{ k: 'rssi_center',  t: '加权中点 (dBm)',     kind: 'num' },
	{ k: 'update',       t: '评估间隔 (秒)',      kind: 'num' },
	{ k: 'bw',           t: '带宽门限 (Mbit/s)',  kind: 'num' }
];

return view.extend({
	load: function () {
		return Promise.all([
			callMeshStatus(),
			uci.load('wireless'),
			uci.load('mesh'),
			/* 漫游灵敏度（r57）：档位 / 总开关 / 高级覆盖项 / 后端算好的生效值。
			   取不到不致命 —— render 里会显示"读取失败"并隐藏控件，而不是拿默认值
			   去覆盖用户的真实配置。 */
			callMeshExec('roam_show').catch(function () { return null; })
		]).then(function (r) {
			var status = r[0] || {};
			var roamRaw = r[3] || null;
			var roam = null;
			if (roamRaw && roamRaw.stdout) {
				try { roam = JSON.parse(roamRaw.stdout); } catch (e) { roam = null; }
			}
			var radios = (status.radios && status.radios.length) ? status.radios : [];
			/* 每个射频各拉一次「可选功率表」+「当前功率」。失败不致命：
			   下面 txField() 拿不到表时会退化成只读标签，不会给用户一个空下拉。 */
			return Promise.all(radios.map(function (rd) {
				return Promise.all([
					/* ★ 位置传参：rd.radio 本身就是字符串（radio0/radio1），不要再包成对象 */
					callIwinfoTxPowerList(rd.radio).catch(function () { return null; }),
					callIwinfoInfo(rd.radio).catch(function () { return null; })
				]).then(function (t) {
					return { radio: rd.radio, list: normList(t[0]), info: t[1] || null };
				});
			})).then(function (arr) {
				var tx = {};
				arr.forEach(function (x) { tx[x.radio] = { list: x.list, info: x.info }; });
				return { status: status, tx: tx, roam: roam };
			});
		});
	},

	render: function (payload) {
		ensureCss();
		payload = payload || {};
		var status = payload.status || {};
		var txData = payload.tx || {};
		var roam = payload.roam || null;

		var meshOn = (Number(status.enabled) === 1);
		var isChild = meshOn && status.role === 'client';
		var bhBand = (status.backhaul && status.backhaul.band) ? status.backhaul.band : null;

		var radios = (status.radios && status.radios.length) ? status.radios : [];
		var radioByBand = {}, bandByRadio = {};
		radios.forEach(function (r) {
			bandByRadio[r.radio] = r.band;
			if (!radioByBand[r.band]) radioByBand[r.band] = r;
		});

		var bands = BAND_ORDER.filter(function (b) { return radioByBand[b]; });
		if (!bands.length) bands = Object.keys(radioByBand);

		/* 用户可编辑的 AP 段：mode=ap，且排除本工具自建段（配对 AP / 镜像段，带
		   mesh_managed=1 或 mesh_pair=1）—— 否则用户会看到并误改 XxMesh-Pair。 */
		var apByBand = {};
		uci.sections('wireless', 'wifi-iface').forEach(function (s) {
			if (s.mode !== 'ap') return;
			if (s.mesh_managed === '1' || s.mesh_pair === '1') return;
			var b = bandByRadio[s.device];
			if (b && !apByBand[b]) apByBand[b] = s;
		});
		var apBands = bands.filter(function (b) { return apByBand[b]; });

		function apEditable() { return !isChild; }
		function chanEditable(b) { return !isChild && (!meshOn || b !== bhBand); }
		function htEditable() { return !isChild; }
		/* 国家码**每节点各自设置**：子节点也可改。它不参与同步
		   （mesh-sync 里根本没有 country），所以子节点上改了不会被主节点覆盖。 */
		function countryEditable() { return true; }
		/* ★ 发射功率**每个节点各自设置**：子节点也可改。txpower 不参与同步
		   （mesh-sync 不下发、meshctl 从不写），所以子节点上改了不会被主节点覆盖。
		   另外**不锁回程频段**（原生无线页本来就能改，锁了只会逼用户绕路）。 */
		function txEditable() { return true; }

		/* 只在值真的变了时才写 UCI —— 否则 uci.set 写入相同值也会留下变更记录，
		   保存时就会白白触发一次无线重载。 */
		var changed = false;
		function setIfChanged(sid, opt, val) {
			var cur = uci.get('wireless', sid, opt);
			cur = (cur == null) ? '' : String(cur);
			val = (val == null) ? '' : String(val);
			if (cur === val) return;
			if (val === '') uci.unset('wireless', sid, opt);
			else uci.set('wireless', sid, opt, val);
			changed = true;
		}

		/* ---------- 当前值 ---------- */
		var ssidByBand = {}, chanByBand = {}, htByBand = {}, txByBand = {};
		bands.forEach(function (b) {
			ssidByBand[b] = apByBand[b] ? (apByBand[b].ssid || '') : '';
			var r = radioByBand[b];
			chanByBand[b] = r.channel || 'auto';
			htByBand[b] = r.htmode || '';
			var tp = uci.get('wireless', r.radio, 'txpower');
			txByBand[b] = (tp == null) ? '' : String(tp);   /* '' = 驱动默认（删除该项） */
		});

		/* 国家码：整机一个。以**实际生效**的 wireless.<radio>.country 为准，
		   退到 mesh.main.country（apply 的来源，见 meshctl:612），再退 CN。 */
		var countryVal = '';
		bands.forEach(function (b) {
			if (!countryVal) countryVal = uci.get('wireless', radioByBand[b].radio, 'country') || '';
		});
		if (!countryVal) countryVal = uci.get('mesh', 'main', 'country') || 'CN';

		var firstAp = apBands.length ? apByBand[apBands[0]] : null;
		var enc = (firstAp && firstAp.encryption) ? firstAp.encryption : 'psk2';
		var key = (firstAp && firstAp.key) ? firstAp.key : '';

		var unified = false;
		var unifiedSsid = apBands.length ? (ssidByBand[apBands[0]] || '') : '';

		/* ---------- 名称与密码 ---------- */
		var ssidArea = E('div', {});

		function renderSsidArea() {
			while (ssidArea.firstChild) ssidArea.removeChild(ssidArea.firstChild);
			if (!apBands.length) {
				ssidArea.appendChild(row(_('WiFi 名称'), E('span', { 'class': 'mesh-tag' }, _('未找到可设置的 WiFi 接口'))));
				return;
			}
			if (!apEditable()) {
				apBands.forEach(function (b) {
					ssidArea.appendChild(row(bandText(b) + ' ' + _('名称'),
						E('span', { 'class': 'mesh-tag' }, ssidByBand[b] || _('（未设置）'))));
				});
				return;
			}
			if (unified) {
				var inp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'maxlength': 32 });
				inp.value = unifiedSsid;
				inp.addEventListener('input', function () { unifiedSsid = inp.value; });
				ssidArea.appendChild(row(_('WiFi 名称'), inp));
			} else {
				apBands.forEach(function (b) {
					var inp = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'maxlength': 32 });
					inp.value = ssidByBand[b] || '';
					inp.addEventListener('input', function () { ssidByBand[b] = inp.value; });
					ssidArea.appendChild(row(bandText(b) + ' ' + _('名称'), inp));
				});
			}
		}

		var chkUnified = E('input', { 'type': 'checkbox' });
		chkUnified.checked = false;
		chkUnified.disabled = !apEditable();
		chkUnified.addEventListener('change', function () {
			unified = chkUnified.checked;
			renderSsidArea();
		});

		var selEnc = E('select', { 'class': 'cbi-input-select' });
		ENC_OPTS.forEach(function (o) { selEnc.appendChild(E('option', { 'value': o.v }, o.t)); });
		selEnc.value = enc;
		selEnc.disabled = !apEditable();

		var inpKey = E('input', { 'class': 'cbi-input-password', 'type': 'password', 'maxlength': 63 });
		inpKey.value = key;

		function syncKeyEnabled() { inpKey.disabled = !apEditable() || enc === 'none'; }
		selEnc.addEventListener('change', function () { enc = selEnc.value; syncKeyEnabled(); });
		inpKey.addEventListener('input', function () { key = inpKey.value; });

		var btnShow = E('button', { 'class': 'cbi-button cbi-button-neutral', 'type': 'button' }, _('显示'));
		btnShow.addEventListener('click', function (ev) {
			ev.preventDefault();
			inpKey.type = (inpKey.type === 'password') ? 'text' : 'password';
			btnShow.textContent = (inpKey.type === 'password') ? _('显示') : _('隐藏');
		});

		syncKeyEnabled();
		renderSsidArea();

		var nameSec = section(_('WiFi 名称与密码'), [
			row(_('双频合一'),
				E('label', { 'class': 'mesh-inline' }, [
					chkUnified, ' ' + _('2.4G 与 5G 用同一个名称（终端自动选更优频段）')
				])),
			ssidArea,
			row(_('加密方式'), selEnc),
			row(_('密码'), apEditable()
				? E('div', {}, [ inpKey, ' ', btnShow ])
				: E('span', { 'class': 'mesh-tag' }, _('由主节点下发')))
		]);

		/* ---------- 信道与带宽 ---------- */
		/* 国家/地区代码：**整机一个**（它决定可用信道与功率上限，逻辑上"先定监管域再选信道"）。
		   短列表；当前值不在表内时补一条，保证已有配置能正常显示、不被静默改写。 */
		function countryLabel(code) {
			var m = COUNTRY_OPTS.filter(function (o) { return o.v === code; })[0];
			return m ? (_(m.t) + ' (' + code + ')') : (code || '—');
		}

		function countryField() {
			/* countryEditable() 目前**恒为 true**（每节点各自设置）；保留只读分支作为将来的钩子 */
			if (!countryEditable())
				return E('span', { 'class': 'mesh-tag' }, countryLabel(countryVal));
			var opts = COUNTRY_OPTS.slice();
			if (!opts.some(function (o) { return o.v === countryVal; }))
				opts.unshift({ v: countryVal, t: countryVal });
			var sel = E('select', { 'class': 'cbi-input-select' });
			opts.forEach(function (o) {
				sel.appendChild(E('option', { 'value': o.v },
					o.t === o.v ? o.v : (_(o.t) + ' (' + o.v + ')')));
			});
			sel.value = countryVal;
			sel.addEventListener('change', function () { countryVal = sel.value; });
			return sel;
		}

		function channelField(b) {
			var r = radioByBand[b];
			if (!chanEditable(b)) {
				var txt;
				if (meshOn && b === bhBand)
					txt = _('跟随回程（%s）').format(String(status.channel || r.channel || ''));
				else
					txt = String(r.channel || '—');
				return E('span', { 'class': 'mesh-tag' }, txt);
			}
			var chans = (status.channels && status.channels[b]) ? status.channels[b].map(String) : [];
			var cur = String(chanByBand[b] || 'auto');
			if (cur !== 'auto' && chans.indexOf(cur) < 0) chans.unshift(cur);
			var sel = E('select', { 'class': 'cbi-input-select' });
			chans.forEach(function (c) { sel.appendChild(E('option', { 'value': c }, c)); });
			sel.appendChild(E('option', { 'value': 'auto' }, _('自动')));
			sel.value = cur;
			sel.addEventListener('change', function () { chanByBand[b] = sel.value; });
			return sel;
		}

		/* 下拉里"每个带宽只留一档"：同一带宽的 HT/VHT/HE 对普通用户是纯噪音，
		   默认取本机支持的最高代际（WiFi 6 > 5 > 4），标签写成「160 MHz · WiFi 6」。
		   当前值若不是该带宽的最优档（如跑在 VHT80 而最优是 HE80），单独列一条
		   「…（当前）」，否则选中项会对不上真实配置；用户不动它就不会被改写。 */
		function htmodeField(b) {
			var r = radioByBand[b];
			var raw = (r.htlist && r.htlist.length) ? r.htlist.slice() : [];
			var cur = htByBand[b] || '';
			/* 当前值不在能力列表里（或为空）时补进去，避免被迫写一个可能把射频降级的带宽 */
			if (raw.indexOf(cur) < 0) raw.unshift(cur);

			var keys = [], best = {};
			raw.forEach(function (h) {
				var m = htmodeParse(h);
				var k = m ? m.mhz : h;
				if (!(k in best)) { keys.push(k); best[k] = h; return; }
				var bm = htmodeParse(best[k]);
				if (m && bm && m.gen > bm.gen) best[k] = h;
			});
			keys.sort(function (x, y) {
				var nx = (typeof x === 'number'), ny = (typeof y === 'number');
				if (nx && ny) return x - y;
				if (nx !== ny) return nx ? -1 : 1;
				return String(x) < String(y) ? -1 : 1;
			});

			if (!htEditable())
				return E('span', { 'class': 'mesh-tag' }, htmodeLabel(cur));

			var sel = E('select', { 'class': 'cbi-input-select' });
			keys.forEach(function (k) {
				var v = best[k];
				sel.appendChild(E('option', { 'value': v }, htmodeLabel(v)));
			});
			var cm = htmodeParse(cur);
			if (cur && best[cm ? cm.mhz : cur] !== cur)
				sel.appendChild(E('option', { 'value': cur }, htmodeLabel(cur) + _('（当前）')));
			sel.value = cur;
			sel.addEventListener('change', function () { htByBand[b] = sel.value; });
			return sel;
		}

		/* 发射功率：**每频段一个**（txpower 是 per-radio）。选项来自 iwinfo.txpowerlist，
		   首项「驱动默认」= 删除 UCI 项（不是写 0）；行尾显示 iwinfo.info 报的实际当前功率。
		   ★ **不锁回程频段** —— 原生无线页本来就能改，锁了只会逼用户绕路（见文件头注释）。 */
		function txField(b) {
			var r = radioByBand[b];
			var t = txData[r.radio] || {};
			var info = t.info || {};
			var cur = txByBand[b] || '';
			var curDbm = Number(info.txpower);
			var curTxt = (isFinite(curDbm) && curDbm > 0) ? _('当前功率: %s dBm').format(curDbm) : '';

			/* txEditable() 目前**恒为 true**（每个节点都能改自己的发射功率）。
			   保留这个只读分支，将来若要按角色/频段锁定，只改 txEditable() 即可。 */
			if (!txEditable(b))
				return E('span', { 'class': 'mesh-tag' },
					(cur ? cur + ' dBm' : _('驱动默认')) + (curTxt ? ' · ' + curTxt : ''));

			var list = t.list;
			if (!list || !list.length) {
				/* 拿不到功率表（接口不可用）：退化成只读标签，别给用户一个空下拉 */
				return E('span', { 'class': 'mesh-tag' },
					curTxt || (cur ? cur + ' dBm' : _('驱动默认')));
			}

			var sel = E('select', { 'class': 'cbi-input-select' });
			sel.appendChild(E('option', { 'value': '' }, _('驱动默认')));
			var seen = {};
			list.forEach(function (p) {
				var dbm = String(p.dbm);
				if (seen[dbm]) return;
				seen[dbm] = 1;
				sel.appendChild(E('option', { 'value': dbm },
					dbm + ' dBm' + (p.mw ? ' (' + p.mw + ' mW)' : '')));
			});
			/* 当前 UCI 值不在表里时补一条，避免选中项对不上真实配置 */
			if (cur && !seen[cur])
				sel.appendChild(E('option', { 'value': cur }, cur + ' dBm' + _('（当前）')));
			sel.value = cur;
			sel.addEventListener('change', function () { txByBand[b] = sel.value; });

			/* select 与提示同在 div 里即为同行（都是行内元素），无需额外 CSS */
			var wrap = E('div', {}, [ sel ]);
			if (curTxt) wrap.appendChild(E('span', { 'class': 'mesh-muted' }, ' - ' + curTxt));
			return wrap;
		}

		var secRows = [ row(_('国家/地区代码'), countryField()) ];
		bands.forEach(function (b) {
			secRows.push(E('div', {}, [
				E('h4', { 'class': 'mesh-band-title' }, bandText(b)),
				row(_('信道'), channelField(b)),
				row(_('通道宽度'), htmodeField(b)),
				row(_('发射功率'), txField(b))
			]));
		});
		secRows.push(E('div', { 'class': 'mesh-muted' },
			'· ' + _('带宽越大速度越快，但越怕干扰：2.4G 建议 20 MHz，5G 建议 80 MHz。')));
		secRows.push(E('div', { 'class': 'mesh-muted' },
			'· ' + _('「WiFi 4 / 5 / 6」是制式代际（数字越高越新），本页已自动为你选本机支持的最高代际。')));
		secRows.push(E('div', { 'class': 'mesh-muted' },
			'· ' + _('国家/地区代码影响可用信道与功率上限；改完后信道列表会在下次进入本页时刷新。')));
		if (meshOn && bhBand)
			secRows.push(E('div', { 'class': 'mesh-muted' },
				'· ' + _('回程频段（%s）的发射功率过低会削弱组网链路，请谨慎调低。').format(bandText(bhBand))));

		var radioSec = section(_('信道与带宽'), secRows);

		/* ---------- 漫游引导（r57） ----------
		 * 独立区块（不塞进「信道与带宽」—— 两者语义无关）。
		 * 数据源 = 后端 meshctl roam_show（档位→dawn 参数的翻译在后端一处）；
		 * 保存只写 mesh.main.roam_*，dawn 由后端 roam_apply 翻译 + reload_config（免重启）。 */
		var roamState = { enabled: true, level: '5', adv: {}, changed: false };
		if (roam) {
			roamState.enabled = (Number(roam.enabled) === 1);
			roamState.level = String(roam.level || 5);
			var rov = roam.overrides || {};
			ROAM_ADV.forEach(function (f) {
				roamState.adv[f.k] = (rov[f.k] == null ? '' : String(rov[f.k]));
			});
		}

		function roamEditable() {
			return !isChild && !!roam && Number(roam.dawn) === 1;
		}

		function roamEff(k) {
			var e = (roam && roam.effective) || {};
			return (e[k] == null ? '—' : String(e[k]));
		}

		function roamSection() {
			var rows = [];
			if (!roam)
				return section(_('漫游引导'), [ note(_('读取漫游设置失败：无法从后端获取档位信息，请刷新页面（Ctrl+F5）后重试。'), 'red') ]);
			if (Number(roam.dawn) !== 1)
				return section(_('漫游引导'), [ note(_('本节点未安装 dawn，无法设置漫游灵敏度。安装 dawn 后本区块会自动可用。'), 'orange') ]);

			if (isChild)
				rows.push(note(_('本节点是子节点：漫游灵敏度由主节点统一管理（每 10 秒自动同步），此处仅供查看。要改请到主节点上操作。'), 'orange'));
			else if (!meshOn)
				rows.push(note(_('当前未启用 Mesh 组网：漫游引导只在有多个 AP 节点时才有意义。'), 'orange'));

			/* --- 灵敏度档位（先建，开关的监听要用到它） --- */
			var levelSel = E('select', { 'class': 'cbi-input-select' });
			ROAM_LEVELS.forEach(function (o) { levelSel.appendChild(E('option', { 'value': o.v }, _(o.t))); });
			levelSel.value = roamState.level;

			/* --- 总开关：关掉 = dawn kicking 0（只写日志"本来会踢谁"，不动作） --- */
			var chk = E('input', { 'type': 'checkbox', 'id': 'mesh-roam-en' });
			chk.checked = roamState.enabled;
			chk.disabled = !roamEditable();
			chk.addEventListener('change', function () {
				roamState.enabled = chk.checked;
				roamState.changed = true;
				levelSel.disabled = !chk.checked || !roamEditable();
			});
			rows.push(row(_('启用漫游引导'), E('label', { 'class': 'mesh-roam-chk', 'for': 'mesh-roam-en' },
				[ chk, _('让设备在节点之间自动切换到信号更好的那个') ])));

			levelSel.disabled = !roamEditable() || !roamState.enabled;
			levelSel.addEventListener('change', function () {
				roamState.level = levelSel.value;
				roamState.changed = true;
			});
			rows.push(row(_('灵敏度'), E('div', { 'class': 'mesh-roam-lv' }, [ levelSel ])));
			rows.push(E('div', { 'class': 'mesh-muted' },
				'· ' + _('档位越高越容易切换：1 最稳（除非另一节点明显更好，否则不动），5 是标准值（dawn 出厂默认），10 最激进（轻微优势就切，节点密集时可能来回跳）。')));
			rows.push(E('div', { 'class': 'mesh-muted' },
				'· ' + _('dawn 的评分是台阶式的，相邻档位未必有明显手感差异 —— 真正不同的是跨台阶的那几档。')));

			/* --- 高级（可折叠）：留空 = 跟随档位，placeholder 显示当前生效值 --- */
			var grid = E('div', { 'class': 'mesh-roam-grid' });
			ROAM_ADV.forEach(function (f) {
				var inp;
				if (f.kind === 'select') {
					inp = E('select', { 'class': 'cbi-input-select' });
					inp.appendChild(E('option', { 'value': '' }, _('跟随档位')));
					ROAM_KICKING_OPTS.forEach(function (o) { inp.appendChild(E('option', { 'value': o.v }, _(o.t))); });
					inp.value = roamState.adv[f.k] || '';
				} else {
					inp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': roamEff(f.k) });
					inp.value = roamState.adv[f.k] || '';
				}
				inp.disabled = !roamEditable();
				inp.addEventListener('change', function () {
					roamState.adv[f.k] = inp.value;
					roamState.changed = true;
				});
				grid.appendChild(E('div', { 'class': 'mesh-roam-field' }, [
					E('label', {}, _(f.t)), inp
				]));
			});

			var btnReset = E('button', { 'class': 'cbi-button cbi-button-neutral', 'type': 'button' }, _('全部跟随档位'));
			btnReset.disabled = !roamEditable();
			btnReset.addEventListener('click', function (ev) {
				/* type=button 已显式写；这里再拦一次，防止某些主题下按钮落在 <form> 里 */
				ev.preventDefault();
				ev.stopPropagation();
				ROAM_ADV.forEach(function (f) { roamState.adv[f.k] = ''; });
				/* 控件同步回填成空（真正的写入在「保存并应用」时统一做） */
				var els = grid.querySelectorAll('input, select');
				for (var i = 0; i < els.length && i < ROAM_ADV.length; i++) els[i].value = '';
				roamState.changed = true;
			});

			rows.push(E('details', { 'class': 'mesh-roam-adv' }, [
				E('summary', {}, _('高级设置（一般不用改）')),
				grid,
				E('div', { 'class': 'mesh-btnrow' }, [ btnReset ]),
				E('div', { 'class': 'mesh-muted' }, '· ' + _('留空 = 跟随档位；输入框里的灰色数字就是当前的生效值。')),
				E('div', { 'class': 'mesh-muted' }, '· ' + _('「加权中点」只在踢人方法选 2 / 3 时生效；「好/差信号门限」影响 dawn 的评分台阶。'))
			]));

			return section(_('漫游引导'), rows);
		}

		var roamSec = roamSection();

		/* ---------- 提示 ---------- */
		var hint;
		if (isChild) {
			hint = note(_('本节点是子节点：WiFi 名称、密码、信道、带宽由主节点统一管理（每 10 秒自动同步），此处仅供查看；国家/地区代码与发射功率是每台设备自己的设置，可以在本页修改。要改其它项请到主节点上操作。'), 'orange');
		} else if (meshOn) {
			hint = note(_('本节点是主节点：SSID / 加密 / 信道 / 带宽会下发到所有子节点；国家码与发射功率仅在本机生效。')
				+ (bhBand ? _('回程频段（%s）的信道与组网绑定，已锁定为「跟随回程」，如需修改请到「组网设置」。').format(bandText(bhBand)) : ''), 'green');
		} else {
			hint = note(_('未启用组网：这里就是一个普通的 WiFi 设置入口，改完保存即可。'), 'green');
		}

		/* ---------- 保存 ---------- */
		/* 漫游灵敏度：只写 mesh.main.roam_*（dawn 由后端 roam_apply 翻译）。
		   ★ 必须去重：uci.set 写相同值也会留下变更记录，进而触发一次无谓的
		     uci.apply（若 wireless 恰好也在本次改动里，就是一次真正的无线重载）。 */
		function roamCollect() {
			if (!roamEditable()) return;
			function mm(opt, val) {
				var cur = uci.get('mesh', 'main', opt);
				cur = (cur == null) ? '' : String(cur);
				if (cur === val) return;
				if (val === '') uci.unset('mesh', 'main', opt);
				else uci.set('mesh', 'main', opt, val);
				changed = true;
				roamState.changed = true;
			}
			mm('roam_enabled', roamState.enabled ? '1' : '0');
			mm('roam_level', roamState.level);
			ROAM_ADV.forEach(function (f) {
				var v = String(roamState.adv[f.k] == null ? '' : roamState.adv[f.k]).replace(/\s+/g, '');
				/* 非整数一律当"跟随档位"（清空），绝不把坏值写进配置 */
				if (v !== '' && !/^-?\d+$/.test(v)) v = '';
				mm('roam_' + f.k, v);
			});
		}

		function doSave() {
			changed = false;
			if (apEditable()) {
				apBands.forEach(function (b) {
					var s = apByBand[b];
					var ssid = unified ? unifiedSsid : (ssidByBand[b] || '');
					if (ssid) setIfChanged(s['.name'], 'ssid', ssid);
					setIfChanged(s['.name'], 'encryption', enc);
					if (enc === 'none') setIfChanged(s['.name'], 'key', '');
					else if (key) setIfChanged(s['.name'], 'key', key);
				});
			}
			/* 国家码：**双写** —— wireless.<每个 radio>.country + mesh.main.country。
			   只写前者的话，下次 meshctl apply 会用 mesh.main.country 覆盖回去（meshctl:612）。 */
			if (countryEditable()) {
				bands.forEach(function (b) { setIfChanged(radioByBand[b].radio, 'country', countryVal); });
				var mc = uci.get('mesh', 'main', 'country');
				if ((mc == null ? '' : String(mc)) !== countryVal) {
					uci.set('mesh', 'main', 'country', countryVal);
					changed = true;
				}
			}
			bands.forEach(function (b) {
				var r = radioByBand[b];
				if (chanEditable(b)) setIfChanged(r.radio, 'channel', chanByBand[b]);
				if (htEditable() && htByBand[b]) setIfChanged(r.radio, 'htmode', htByBand[b]);
				/* 发射功率：空值走 setIfChanged 的 uci.unset 分支 = 「驱动默认」 */
				if (txEditable()) setIfChanged(r.radio, 'txpower', txByBand[b]);
			});

			/* 漫游档位：记下"除了漫游还有没有别的改动" —— 只改漫游时不需要 wifi 重载，
			   提示文案也就不该说"无线重启约 10~20 秒"。 */
			var otherChanged = changed;
			roamCollect();
			var roamOnly = (!otherChanged && changed);

			if (!changed) {
				ui.addNotification(null, E('p', {}, _('没有需要保存的改动')), 'info');
				return Promise.resolve();
			}

			return uci.save()
				.then(function () { return uci.apply(30); })
				.catch(function (rv) {
					if (isNoData(rv)) return null;
					return Promise.reject(rv);
				})
				.then(function () {
					/* 组网时补一次自愈：热重载可能把某个频段的 AP 留在 disabled（mt76 -122） */
					if (meshOn) return callMeshExec('wifi_ensure').catch(function () {});
				})
				.then(function () {
					/* dawn 配置不受 uci.apply 管辖（它只管 uci 配置）——必须显式让后端
					   把 mesh.main.roam_* 翻译进 /etc/config/dawn 并 reload_config。
					   无变化时后端不 commit、不 reload，所以这一步可以无条件调。 */
					if (roamState.changed) return callMeshExec('roam_apply').catch(function () {});
				})
				.then(function () {
					ui.addNotification(null, E('p', {}, roamOnly
						? _('已保存：漫游灵敏度已生效（无需重启无线）。')
						: _('已保存并应用：无线重启约 10~20 秒，期间连接可能中断。')), 'success');
				}, function (e) {
					ui.addNotification(null, E('p', {}, _('保存失败：%s').format(e)), 'danger');
					return Promise.reject(e);
				});
		}

		var btnSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('保存并应用'));
		btnSave.addEventListener('click', function () {
			btnSave.disabled = true;
			doSave().then(function () { btnSave.disabled = false; },
				function () { btnSave.disabled = false; });
		});

		/* 当前状态下有没有可改的项：发射功率恒可改，所以正常都会有；这里只兜「一个射频都没有」的极端情况 */
		var anyEditable = apEditable() || countryEditable() || roamEditable() || bands.some(function (b) {
			return chanEditable(b) || htEditable() || txEditable();
		});

		var actSec = section(_('应用'), [
			anyEditable
				? E('div', { 'class': 'mesh-btnrow' }, [ btnSave ])
				: E('div', { 'class': 'mesh-muted' }, '· ' + _('本页当前没有可修改的项。')),
			E('div', { 'class': 'mesh-muted' }, [
				E('div', {}, '· ' + _('本页只是「网络 → 无线」的快捷入口，两者共用同一份配置，改哪边都一样。')),
				E('div', {}, '· ' + _('保存后无线会重载一次（约 10~20 秒），期间连接可能短暂中断；只改漫游灵敏度时不会重启无线。'))
			])
		]);

		return E('div', {}, [ hint, nameSec, radioSec, roamSec, actSec ]);
	}
});
