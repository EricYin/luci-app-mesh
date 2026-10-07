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
 *
 * 组网联动（未组网时全部可改，就是一个普通 WiFi 页）：
 *   · 主节点：SSID/加密/带宽可改（它就是同步源）；**回程频段的信道锁定为「跟随回程」**
 *     —— 回程频段与回程共用同一射频，改了会拆掉组网，故只读，要改请去「组网设置」。
 *   · 子节点：SSID/加密/信道/带宽全部由主节点下发（每 10 秒镜像覆盖），一律只读。
 *
 * 保存：uci.set -> uci.save() -> uci.apply()（落盘并触发无线重载）-> 组网时再调
 *   meshctl wifi_ensure 补一次自愈（防 mt76 热重载 -122 把 AP 留在 disabled）。
 *   ★ 必须 uci.save()：rpcd 的 uci.set 只在会话内存里，shell / meshctl 看不到；而
 *     luci/uci.js 的 apply() 只提交 rpcd 已暂存的内容，不会替你 save（见其源码）。
 * ========================================================================== */

var callMeshStatus = rpc.declare({ object: 'mesh', method: 'status', expect: {} });
var callMeshExec = rpc.declare({ object: 'mesh', method: 'exec', params: [ 'cmd' ], expect: {} });

var ENC_OPTS = [
	{ v: 'psk2', t: 'WPA2-PSK' },
	{ v: 'psk', t: 'WPA-PSK' },
	{ v: 'sae', t: 'WPA3-SAE' },
	{ v: 'sae-mixed', t: 'WPA3 / WPA2 混合' },
	{ v: 'none', t: '不加密（开放）' }
];

var BAND_ORDER = [ '2g', '5g', '6g' ];

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

return view.extend({
	load: function () {
		return Promise.all([
			callMeshStatus(),
			uci.load('wireless')
		]).then(function (r) { return r[0] || {}; });
	},

	render: function (status) {
		ensureCss();
		status = status || {};

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
		var ssidByBand = {}, chanByBand = {}, htByBand = {};
		bands.forEach(function (b) {
			ssidByBand[b] = apByBand[b] ? (apByBand[b].ssid || '') : '';
			var r = radioByBand[b];
			chanByBand[b] = r.channel || 'auto';
			htByBand[b] = r.htmode || '';
		});
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

		var radioSec = section(_('信道与带宽'), bands.map(function (b) {
			return E('div', {}, [
				E('h4', { 'class': 'mesh-band-title' }, bandText(b)),
				row(_('信道'), channelField(b)),
				row(_('通道宽度'), htmodeField(b))
			]);
		}).concat([
			E('div', { 'class': 'mesh-muted' },
				'· ' + _('带宽越大速度越快，但越怕干扰：2.4G 建议 20 MHz，5G 建议 80 MHz。')),
			E('div', { 'class': 'mesh-muted' },
				'· ' + _('「WiFi 4 / 5 / 6」是制式代际（数字越高越新），本页已自动为你选本机支持的最高代际。'))
		]));

		/* ---------- 提示 ---------- */
		var hint;
		if (isChild) {
			hint = note(_('本节点是子节点：WiFi 名称、密码、信道、带宽均由主节点统一管理，每 10 秒自动同步，此处仅供查看。要修改请到主节点上操作。'), 'orange');
		} else if (meshOn) {
			hint = note(_('本节点是主节点：这里的 WiFi 设置会下发到所有子节点。')
				+ (bhBand ? _('回程频段（%s）的信道与组网绑定，已锁定为「跟随回程」，如需修改请到「组网设置」。').format(bandText(bhBand)) : ''), 'green');
		} else {
			hint = note(_('未启用组网：这里就是一个普通的 WiFi 设置入口，改完保存即可。'), 'green');
		}

		/* ---------- 保存 ---------- */
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
			bands.forEach(function (b) {
				var r = radioByBand[b];
				if (chanEditable(b)) setIfChanged(r.radio, 'channel', chanByBand[b]);
				if (htEditable() && htByBand[b]) setIfChanged(r.radio, 'htmode', htByBand[b]);
			});

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
					ui.addNotification(null, E('p', {},
						_('已保存并应用：无线重启约 10~20 秒，期间连接可能中断。')), 'success');
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

		/* 当前状态下有没有可改的项：子节点全部只读，就不放一个永远点不动的保存按钮 */
		var anyEditable = apEditable() || bands.some(function (b) {
			return chanEditable(b) || htEditable();
		});

		var actSec = section(_('应用'), [
			anyEditable
				? E('div', { 'class': 'mesh-btnrow' }, [ btnSave ])
				: E('div', { 'class': 'mesh-muted' }, '· ' + _('本页当前没有可修改的项：子节点的无线设置由主节点统一管理。')),
			E('div', { 'class': 'mesh-muted' }, [
				E('div', {}, '· ' + _('本页只是「网络 → 无线」的快捷入口，两者共用同一份配置，改哪边都一样。')),
				E('div', {}, '· ' + _('保存后无线会重载一次（约 10~20 秒），期间连接可能短暂中断。'))
			])
		]);

		return E('div', {}, [ hint, nameSec, radioSec, actSec ]);
	}
});
