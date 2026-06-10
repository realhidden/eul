/* ============================================================
   eul 2.0 — interactive prototype
   Two first-class surfaces: the menu-bar item (with a width-pressure
   rig simulating a 14" notched bar filling with third-party icons)
   and the investigation panel, clickable end-to-end for the
   "why is my fan spinning?" flow, including fan Auto/Manual/Boost.

   Target is native SwiftUI on NSStatusItem + MenuBarExtra.
   Comments marked WEB-FREEDOM flag anything that assumes web
   rendering freedom and must NOT carry over to the native build.
   Energy rules (doc §5.5): nothing animates in the bar; all values
   re-render at the refresh cadence T.time.refreshMs.
   ============================================================ */
(function () {
  'use strict';

  /* ---------------- design tokens (named constants — no magic numbers) ---------------- */
  var T = {
    bar: {                       /* logical px on a 14" MBP (1512 wide) — doc §2.3 */
      width: 1512,
      notch: 200,                /* notch width incl. safe margin */
      edgePad: 14,
      systemItems: 204,          /* wifi + battery + 3rd-party-ish + clock */
      thirdPartyItem: 29,        /* one generic status icon */
      anchor: 34,                /* eul anchor incl. padding */
      slotCpu: 79,
      slotNet: 76,
      slotFan: 85
    },
    time: {
      refreshMs: 2000,           /* default cadence — doc §4.4 (range 1–10 s) */
      panelOpenMs: 180,          /* the only two animations in the product — doc §5.5 */
      tileExpandMs: 160
    },
    fans: {
      min: 1296, max: 6156,      /* hardware-clamped bounds read from SMC */
      defaultTarget: 4200
    },
    health: { normal: 'normal', elevated: 'elevated', critical: 'critical' }
  };

  /* ---------------- prototype state ---------------- */
  var S = {
    mode: new URLSearchParams(location.search).get('embed') || 'full',
    light: false,
    scenario: 'normal',          /* 'normal' | 'fan' (thermal / runaway scenario) */
    thirdParty: 5,
    /* personalization (doc §4.7): stored once, applies everywhere — bar, panel, widgets, CSV */
    unitBits: localStorage.getItem('eul-proto-unit-bits') === '1',
    tempF: localStorage.getItem('eul-proto-temp-f') === '1',
    panelOpen: false,
    helper: 'none',              /* none | sheet | waiting | installed | removedFlash */
    fans: [
      { name: 'Left',  mode: 'auto', target: T.fans.defaultTarget },
      { name: 'Right', mode: 'auto', target: T.fans.defaultTarget }
    ],
    overrideSince: null,
    procLens: 'cpu',
    cpuExpanded: false,
    cpu: [], net: [], timer: null
  };
  for (var i = 0; i < 40; i++) { S.cpu.push(9 + Math.random() * 7); S.net.push(0.4 + Math.random() * 2.2); }

  function abnormal() { return S.scenario === 'fan'; }
  function overrideActive() { return S.fans.some(function (f) { return f.mode !== 'auto'; }); }
  function fanRpm(f) {
    if (f.mode === 'boost') return T.fans.max;
    if (f.mode === 'manual') return f.target;
    return abnormal() ? 6020 + Math.round(Math.random() * 160) : 2780 + Math.round(Math.random() * 120);
  }

  /* ---------------- shared snippets ---------------- */
  function eyes(w) {
    return '<svg class="eyes" viewBox="0 0 20 12" width="' + w + '" height="' + Math.round(w * 0.6) + '" aria-hidden="true">'
      + '<circle class="ering" cx="6" cy="6" r="4.2"></circle><circle class="ering er" cx="14" cy="6" r="4.2"></circle>'
      + '<circle class="epup" cx="6" cy="6" r="1.5"></circle><circle class="epup epr" cx="14" cy="6" r="1.5"></circle></svg>';
  }
  function glyphState() { return abnormal() ? T.health.elevated : T.health.normal; }
  function sparkSVG() {
    return '<svg class="spark" viewBox="0 0 100 26" preserveAspectRatio="none" aria-hidden="true">'
      + '<path class="sfill" d=""></path><polyline class="sline" points=""></polyline></svg>';
  }
  function drawSpark(svg, data, max) {
    if (!svg) return;
    var pts = data.map(function (v, i) {
      return ((i / (data.length - 1)) * 100).toFixed(1) + ',' + (24 - (Math.min(v, max) / max) * 21).toFixed(1);
    });
    svg.querySelector('.sline').setAttribute('points', pts.join(' '));
    svg.querySelector('.sfill').setAttribute('d', 'M0,26 L' + pts.join(' L') + ' L100,26 Z');
  }
  function fmtRate(v) {
    /* unit personalization (doc §4.7): bits vs bytes, one choice, everywhere */
    if (S.unitBits) {
      var b = v * 8;
      return b >= 1 ? b.toFixed(1) + ' Mb/s' : Math.round(b * 1000) + ' Kb/s';
    }
    return v >= 1 ? v.toFixed(1) + ' MB/s' : Math.round(v * 1000) + ' KB/s';
  }
  function rateParts(v) { var s = fmtRate(v).split(' '); return [s[0], s[1]]; }
  function fmtTemp(c) { return S.tempF ? Math.round(c * 9 / 5 + 32) + '°F' : c + '°C'; }
  /* WEB-FREEDOM: the dotted-underline hover hint on unit chips is a web
     affordance; native build uses a plain clickable text + Settings mirror. */
  function uchip(kind, text) { return '<button class="uchip tnum" data-uchip="' + kind + '" title="Click to change units — applies everywhere">' + text + '</button>'; }
  function fmtRpm(v) { return v.toLocaleString('en-US'); }

  /* ---------------- the width governor (doc §2.2 model D + §2.3) ----------------
     Priority order ships as CPU > NET (doc §2.8): NET drops first.
     The FAN slot is exempt while an override is active (doc §2.7).
     [new infra / uncertain feasibility]: real occlusion detection — ask #3. */
  function governor() {
    var capacity = T.bar.width / 2 - T.bar.notch / 2 - T.bar.edgePad;
    var avail = capacity - T.bar.systemItems - S.thirdParty * T.bar.thirdPartyItem;
    var fan = overrideActive();
    var need = T.bar.anchor + (fan ? T.bar.slotFan : 0);
    var out = { avail: Math.round(avail), fan: fan, cpu: false, net: false, anchor: true, state: 'floor' };
    if (avail < need) { out.anchor = false; out.fan = false; out.state = 'hidden'; return out; }
    if (avail >= need + T.bar.slotCpu) { out.cpu = true; need += T.bar.slotCpu; }
    if (avail >= need + T.bar.slotNet) { out.net = true; need += T.bar.slotNet; }
    out.state = out.cpu && out.net ? 'comfortable' : (out.cpu || out.net) ? 'tight' : 'floor';
    return out;
  }

  /* ---------------- bar rendering ---------------- */
  function barHTML(g) {
    function gi(kind) { return '<span class="mi"><span class="gi ' + kind + '"></span></span>'; }
    var kinds = ['circle', 'square', 'half', 'diamond', 'disc', 'pill', 'circle', 'square', 'diamond', 'half', 'disc', 'circle', 'square', 'half', 'diamond', 'disc'];
    var third = kinds.slice(0, S.thirdParty).map(gi).join('');
    var eul = '';
    if (g.anchor) {
      if (g.fan) eul += '<span class="mi eul-slot" id="barFan"><i class="sl">FAN</i><b class="sv tnum">' + fmtRpm(fanRpm(S.fans[0])) + '</b></span>';
      if (g.cpu) eul += '<span class="mi eul-slot"><i class="sl">CPU</i><b class="sv tnum" id="barCpu">12%</b></span>';
      if (g.net) eul += '<span class="mi eul-slot eul-net"><span class="nrow"><i>↓</i><b id="barNetD">2.4 MB/s</b></span><span class="nrow"><i>↑</i><b id="barNetU">184 KB/s</b></span></span>';
      eul += '<span class="mi eul-anchor state-' + glyphState() + '" id="anchorBtn" role="button" aria-label="eul">' + eyes(18) + '</span>';
    }
    return '<span class="mi"><span class="gi disc"></span></span><span class="mi mname">Finder</span>'
      + ['File', 'Edit', 'View', 'Go', 'Window', 'Help'].map(function (m) { return '<span class="mi mtxt">' + m + '</span>'; }).join('')
      + '<div class="notch"></div><span class="mb-spring"></span>'
      + third + eul
      + '<span class="mi"><span class="gi circle"></span></span>'
      + '<span class="mi sys"><svg viewBox="0 0 16 12" width="15" height="11"><path d="M1.6 4.6a9.2 9.2 0 0 1 12.8 0" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"></path><path d="M4.1 7.1a5.6 5.6 0 0 1 7.8 0" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"></path><circle cx="8" cy="9.9" r="1.5" fill="currentColor"></circle></svg></span>'
      + '<span class="mi sys"><span class="batt"><span class="bcase"><span class="bfill"></span></span><span class="bnub"></span></span></span>'
      + '<span class="mi clock">Tue Jun 10&nbsp;&nbsp;9:41 AM</span>';
  }

  function renderBar() {
    var host = document.getElementById('barHost');
    if (!host) return;
    var g = governor();
    /* the panel is anchored to the item — if macOS hides the item, the panel goes with it */
    if (g.state === 'hidden' && S.panelOpen && S.mode !== 'panel') S.panelOpen = false;
    var labels = { comfortable: 'COMFORTABLE — all pinned slots fit', tight: 'TIGHT — governor dropped NET (lowest priority)', floor: 'FLOOR — anchor only; still a working product', hidden: 'HIDDEN — macOS hid even the anchor → recovery flow (doc §2.5)' };
    host.innerHTML =
      '<div class="display' + (S.light ? ' light' : '') + '" id="displayEl">'
      + '<div class="display-scale" id="dispScale"><div class="proto-bar-wrap">'
      + '<div class="mbwall ' + (S.light ? 'light' : 'dark') + ' wide" style="padding:0;background:none;"><div class="mbbar">' + barHTML(g) + '</div></div>'
      + '</div></div>'
      + '<div class="gov-readout"><span>governor: <b>' + g.state.toUpperCase() + '</b></span>'
      + '<span>space for eul: <b>' + Math.max(0, g.avail) + ' pt</b></span>'
      + '<span>' + labels[g.state] + '</span></div>'
      + (g.state === 'hidden' ? recoveryNotif() : '')
      + '<div class="panel-anchor" id="panelSlot"></div>'
      + '</div>';
    syncDisplayHeight();
    fitDisplay();
    var a = document.getElementById('anchorBtn');
    if (a) a.addEventListener('click', function (e) { e.stopPropagation(); togglePanel(); });
    if (S.panelOpen) renderPanel(false);
    tick(true);
  }

  function recoveryNotif() {
    return '<div class="notif"><span class="n-icon" style="color:#f4f4f6;">' + eyes(16) + '</span>'
      + '<span><b>eul is hidden</b><span>Your menu bar is full. Open eul to choose what to show.</span></span></div>';
  }

  function fitDisplay() {
    var disp = document.getElementById('displayEl');
    if (!disp) return;
    var s = Math.min(1, disp.clientWidth / T.bar.width);
    var sc = document.getElementById('dispScale');
    sc.style.transform = 'scale(' + s + ')';
    sc.style.height = (24 * s) + 'px';
    positionPanel(s);
  }
  function positionPanel(scale) {
    var slot = document.getElementById('panelSlot');
    var a = document.getElementById('anchorBtn');
    var disp = document.getElementById('displayEl');
    if (!slot || !disp) return;
    if (a) {
      var ar = a.getBoundingClientRect(), dr = disp.getBoundingClientRect();
      var x = ar.left - dr.left + ar.width / 2;
      slot.style.left = Math.max(8, Math.min(x - 320, dr.width - 376)) + 'px';
    } else {
      slot.style.left = Math.max(8, disp.clientWidth - 420) + 'px';
    }
  }

  function syncDisplayHeight() {
    var d = document.getElementById('displayEl');
    if (!d) return;
    var hidden = governor().state === 'hidden';
    d.style.minHeight = S.panelOpen ? '700px' : hidden ? '130px' : '';
  }

  function togglePanel() {
    S.panelOpen = !S.panelOpen;
    if (S.panelOpen) renderPanel(true);
    else { var s = document.getElementById('panelSlot'); if (s) s.innerHTML = ''; }
    syncDisplayHeight();
  }

  /* ---------------- the panel (doc §2.6–2.7) ---------------- */
  var PROCS = {
    cpu: [['Safari', 'S', '#2a6fdb', '8.2%'], ['WindowServer', 'W', '#5b5b66', '6.1%'], ['Figma', 'F', '#9a4fd1', '4.8%']],
    mem: [['Figma', 'F', '#9a4fd1', '1.9 GB'], ['Safari', 'S', '#2a6fdb', '1.2 GB'], ['Mail', 'M', '#3a86c8', '640 MB']],
    net: [['Safari', 'S', '#2a6fdb', '↓ 1.9 MB/s'], ['Dropbox', 'D', '#2f7dc4', '↓ 310 KB/s'], ['Mail', 'M', '#3a86c8', '↓ 12 KB/s']]
  };
  function procRows() {
    var rows = '';
    if (abnormal() && S.procLens === 'cpu') {
      rows += '<div class="prow culprit"><span class="picon" style="background:#3478c6;">X</span>'
        + '<span class="pname">Xcode <span class="pdur">· 4 m above threshold</span></span><span class="pval tnum">312%</span></div>';
    }
    PROCS[S.procLens].forEach(function (p) {
      rows += '<div class="prow"><span class="picon" style="background:' + p[2] + ';">' + p[1] + '</span>'
        + '<span class="pname">' + p[0] + '</span><span class="pval tnum">' + p[3] + '</span></div>';
    });
    return rows;
  }
  function coreSet(label, count, base) {
    var h = '<span class="coreset"><span class="cg-label">' + label + '</span>';
    for (var i = 0; i < count; i++) {
      var v = abnormal() ? 68 + Math.random() * 28 : base + Math.random() * 14;
      h += '<span class="core"><i style="height:' + Math.round(v) + '%;"></i></span>';
    }
    return h + '</span>';
  }

  function fansTile() {
    var abn = abnormal();
    var locked = S.helper !== 'installed';
    var exp = S.fansExpanded ? ' expanded' : '';
    var inner = '<div class="t-top"><span class="t-label">FANS</span><span class="t-aux">' + (overrideActive() ? 'Manual' : 'Auto') + '</span></div>'
      + '<div class="t-mid tnum"><i>L</i><span id="fanL">' + fmtRpm(fanRpm(S.fans[0])) + ' rpm</span></div>'
      + '<div class="t-mid tnum"><i>R</i><span id="fanR">' + fmtRpm(fanRpm(S.fans[1])) + ' rpm</span></div>'
      + '<div class="t-sub">' + (S.helper === 'removedFlash' ? 'Helper removed — fans are system-managed.' : abn ? 'ramping — thermal' : 'system managed') + '</div>';
    if (S.fansExpanded) {
      inner += '<div class="t-detail" style="display:block;">';
      if (locked) {
        /* Discovery: a single quiet affordance where the data lives (doc §4.6).
           No badge, no banner, no onboarding mention — P6. */
        inner += '<div class="fan-admin"><span class="t-sub" style="margin:0;">Fans are managed by macOS.</span>'
          + '<button class="fan-cta" id="fanEnable">Control fans…</button></div>';
      } else {
        inner += '<div class="fan-rows">' + S.fans.map(function (f, i) {
          var h = '<div class="fan-row"><div class="fan-row-top"><span class="fan-name">' + f.name + '</span>'
            + '<span class="fan-rpm tnum">' + fmtRpm(fanRpm(f)) + ' rpm</span>'
            + '<span class="fan-modes" data-fan="' + i + '">'
            + ['auto', 'manual', 'boost'].map(function (m) {
              return '<button data-mode="' + m + '" aria-pressed="' + (f.mode === m) + '">' + (m === 'auto' ? 'Auto' : m === 'manual' ? 'Manual' : 'Boost') + '</button>';
            }).join('') + '</span></div>';
          if (f.mode === 'manual') {
            h += '<div class="fan-slider tnum"><span>' + fmtRpm(T.fans.min) + '</span>'
              + '<input type="range" min="' + T.fans.min + '" max="' + T.fans.max + '" step="50" value="' + f.target + '" data-fanslider="' + i + '">'
              + '<span>' + fmtRpm(T.fans.max) + '</span></div>'
              + '<div class="fan-target">target <b>' + fmtRpm(f.target) + '</b> · actual <b>' + fmtRpm(fanRpm(f)) + '</b> rpm</div>';
          }
          if (f.mode === 'boost') h += '<div class="fan-target">full blast · <b>' + fmtRpm(T.fans.max) + '</b> rpm (hardware max)</div>';
          return h + '</div>';
        }).join('') + '</div>'
        /* Trust & safety: fixed strip, always visible with the controls — never a dialog (doc §4.6) */
        + '<div class="safety"><span>Clamped to hardware limits</span><span>macOS can always cool past your setting</span><span>Reverts to Auto when eul quits</span></div>'
        + '<div class="fan-admin"><button class="fan-link" id="fanRemove">Remove helper…</button>'
        + (overrideActive() ? '<button class="fan-cta" id="fanRevert">Revert to Auto</button>' : '') + '</div>';
      }
      inner += '</div>';
    }
    return '<div class="tile' + exp + (abn && !S.fansExpanded ? '' : '') + '" data-fanstile="1" style="cursor:pointer;">' + inner + '</div>';
  }

  function helperSheet() {
    if (S.helper !== 'sheet' && S.helper !== 'waiting') return '';
    var body;
    if (S.helper === 'sheet') {
      body = '<h5>Install the Fan Helper?</h5>'
        + '<p>Controlling fans means writing to your Mac’s hardware (SMC), which macOS only allows through a small privileged helper.</p>'
        + '<ul><li>Installs one helper, approved by you in System Settings</li>'
        + '<li>Targets are clamped to the fan’s real limits; macOS can always cool past them</li>'
        + '<li>Fans revert to Auto whenever eul isn’t running</li>'
        + '<li>Remove it anytime: Fans → Remove helper</li></ul>'
        + '<div class="sheet-btns"><button class="rig-btn" id="shNo">Not now</button><button class="rig-btn" id="shGo" style="background:#1d1d1f;color:#fff;border-color:#1d1d1f;">Install Helper…</button></div>';
    } else {
      body = '<h5>Waiting for approval…</h5>'
        + '<p>macOS is asking for your approval in System Settings → Login Items &amp; Extensions.</p>'
        + '<div class="sheet-sim"><small>PROTOTYPE CHROME — simulates the System Settings outcome</small>'
        + '<div class="sheet-btns" style="margin:0;"><button class="rig-btn" id="shDeny">User denies</button><button class="rig-btn" id="shApprove">User approves</button></div></div>';
    }
    return '<div class="sheet-veil"><div class="sheet">' + body + '</div></div>';
  }

  function renderPanel(animate) {
    var slot = document.getElementById('panelSlot') || document.getElementById('panelHost');
    if (!slot) return;
    var abn = abnormal();
    var ovr = overrideActive();
    var mins = S.overrideSince ? Math.max(1, Math.round((Date.now() - S.overrideSince) / 60000)) : 0;
    slot.innerHTML = '<div class="panel' + (abn ? ' abnormal' : '') + (S.light ? ' light' : '') + (animate ? ' panel-pop' : '') + '" id="eulPanel" data-screen-label="Panel">'
      + '<header class="p-head"><span class="p-glyph state-' + glyphState() + '">' + eyes(17) + '</span>'
      + '<div class="p-title"><b>' + (abn ? 'CPU elevated — Xcode' : 'All systems normal') + '</b>'
      + '<span>' + (abn ? 'thermal pressure moderate · for 9 min' : 'up 6 days · nothing needs you') + '</span>'
      + (ovr ? '<span class="p-override">Manual fan override · ' + mins + ' min — <button class="fan-link" id="hdrRevert">Revert to Auto</button></span>' : '')
      + '</div><button class="p-gear" aria-label="eul settings">···</button></header>'
      + '<div class="p-grid">'
      + '<div class="tile tile-cpu' + (abn ? ' abn' : '') + ((abn || S.cpuExpanded) ? ' expanded' : '') + '" data-expand="cpu">'
      + '<div class="t-top"><span class="t-label">CPU</span><span class="t-aux tnum">' + uchip('temp', fmtTemp(abn ? 96 : 62)) + '</span></div>'
      + '<div class="t-big" id="vCpu">12%</div>' + sparkSVG()
      + '<div class="t-sub">' + (abn ? 'thermal pressure moderate' : 'nominal · 12 cores') + '</div>'
      + '<div class="t-detail"><div class="coregrid">' + coreSet('E', 6, 8) + coreSet('P', 6, 5) + '</div>'
      + '<div class="cg-meta tnum">load 2.31 · 1.98 · 1.74&nbsp;&nbsp;·&nbsp;&nbsp;up 6 d 4 h</div></div></div>'
      + '<div class="tile"><div class="t-top"><span class="t-label">MEMORY</span><span class="t-aux tnum">swap 0 MB</span></div>'
      + '<div class="t-big tnum">58%</div>'
      + '<div class="segbar"><i class="s1" style="width:38%;"></i><i class="s2" style="width:14%;"></i><i class="s3" style="width:6%;"></i></div>'
      + '<div class="t-sub">app 11.2 · wired 4.1 · compressed 1.7 GB</div></div>'
      + '<div class="tile"><div class="t-top"><span class="t-label">NETWORK</span><span class="t-aux">Wi-Fi · en0</span></div>'
      + '<div class="t-mid tnum"><i>↓</i><span id="vNetD">2.4</span>&nbsp;' + uchip('rate', rateParts(S.net[S.net.length - 1])[1]) + '</div>'
      + '<div class="t-mid tnum"><i>↑</i><span id="vNetU">184</span>&nbsp;' + uchip('rate', 'KB/s') + '</div>' + sparkSVG() + '</div>'
      + '<div class="tile"><div class="t-top"><span class="t-label">GPU</span><span class="t-aux tnum">' + uchip('temp', fmtTemp(41)) + '</span></div>'
      + '<div class="t-big tnum" id="vGpu">7%</div><div class="t-sub">M3 Pro · 18 cores</div></div>'
      + '<div class="tile"><div class="t-top"><span class="t-label">DISK</span><span class="t-aux tnum">78%</span></div>'
      + '<div class="t-big tnum" style="font-size:19px;">112 GB <span style="font-size:11px;font-weight:500;color:var(--pp-ink2);">free</span></div>'
      + '<div class="segbar"><i class="s1" style="width:78%;"></i></div>'
      + '<div class="t-sub">Macintosh HD · 494 GB</div></div>'
      + fansTile()
      + '<div class="tile"><div class="t-top"><span class="t-label">BATTERY</span><span class="t-aux tnum">4:10 left</span></div>'
      + '<div class="t-big tnum">84%</div><div class="t-sub tnum">health 91% · 213 cycles</div></div>'
      + '<div class="tile"><div class="t-top"><span class="t-label">BLUETOOTH</span><span class="t-aux">3 devices</span></div>'
      + '<div class="t-mid tnum"><i>AirPods Pro</i></div>'
      + '<div class="t-sub tnum">L 71 · R 68 · case 90</div>'
      + '<div class="t-sub tnum">Magic Keyboard 64%</div></div>'
      + '</div>'
      + '<div class="p-procs"><div class="p-sec"><span>TOP PROCESSES</span><div class="seg" role="group">'
      + ['cpu', 'mem', 'net'].map(function (l) {
        return '<button data-lens="' + l + '" aria-pressed="' + (S.procLens === l) + '">' + (l === 'cpu' ? 'CPU' : l === 'mem' ? 'Memory' : 'Network') + '</button>';
      }).join('') + '</div></div><div id="pRows">' + procRows() + '</div></div>'
      + '<footer class="p-foot"><span>Updated every ' + (T.time.refreshMs / 1000) + ' s</span><span class="tnum">eul is using 0.3% CPU</span></footer>'
      + helperSheet() + '</div>';
    wirePanel(slot);
    tick(true);
  }

  function wirePanel(slot) {
    var panel = slot.querySelector('#eulPanel');
    if (!panel) return;
    panel.addEventListener('click', function (e) { e.stopPropagation(); });
    panel.querySelectorAll('.seg button').forEach(function (b) {
      b.addEventListener('click', function () {
        S.procLens = b.getAttribute('data-lens');
        panel.querySelectorAll('.seg button').forEach(function (x) { x.setAttribute('aria-pressed', String(x === b)); });
        panel.querySelector('#pRows').innerHTML = procRows();
      });
    });
    var cpuTile = panel.querySelector('[data-expand="cpu"]');
    if (cpuTile) cpuTile.addEventListener('click', function (e) {
      if (e.target.closest('button')) return;
      S.cpuExpanded = !S.cpuExpanded;
      renderPanel(false);
    });
    /* personalization at the point of use (doc §4.7): click a unit, it changes everywhere */
    panel.querySelectorAll('[data-uchip]').forEach(function (b) {
      b.addEventListener('click', function (e) {
        e.stopPropagation();
        if (b.getAttribute('data-uchip') === 'rate') {
          S.unitBits = !S.unitBits;
          localStorage.setItem('eul-proto-unit-bits', S.unitBits ? '1' : '0');
        } else {
          S.tempF = !S.tempF;
          localStorage.setItem('eul-proto-temp-f', S.tempF ? '1' : '0');
        }
        renderPanel(false); renderBarIfLive();
      });
    });
    var ft = panel.querySelector('[data-fanstile]');
    if (ft) ft.addEventListener('click', function (e) {
      if (e.target.closest('button') || e.target.closest('input')) return;
      S.fansExpanded = !S.fansExpanded;
      if (S.helper === 'removedFlash') S.helper = 'none';
      renderPanel(false);
    });
    var en = panel.querySelector('#fanEnable');
    if (en) en.addEventListener('click', function () { S.helper = 'sheet'; renderPanel(false); });
    var no = panel.querySelector('#shNo');
    if (no) no.addEventListener('click', function () { S.helper = 'none'; renderPanel(false); });
    var go = panel.querySelector('#shGo');
    if (go) go.addEventListener('click', function () { S.helper = 'waiting'; renderPanel(false); });
    var ap = panel.querySelector('#shApprove');
    if (ap) ap.addEventListener('click', function () { S.helper = 'installed'; renderPanel(false); });
    var dn = panel.querySelector('#shDeny');
    if (dn) dn.addEventListener('click', function () { S.helper = 'none'; renderPanel(false); });
    var rm = panel.querySelector('#fanRemove');
    if (rm) rm.addEventListener('click', function () {
      S.helper = 'removedFlash'; setFansAuto(); renderPanel(false); renderBarIfLive();
    });
    panel.querySelectorAll('.fan-modes button').forEach(function (b) {
      b.addEventListener('click', function () {
        var f = S.fans[+b.parentElement.getAttribute('data-fan')];
        f.mode = b.getAttribute('data-mode');
        if (overrideActive() && !S.overrideSince) S.overrideSince = Date.now();
        if (!overrideActive()) S.overrideSince = null;
        renderPanel(false); renderBarIfLive();
      });
    });
    panel.querySelectorAll('[data-fanslider]').forEach(function (r) {
      r.addEventListener('input', function () {
        var f = S.fans[+r.getAttribute('data-fanslider')];
        f.target = +r.value;
        var tEl = r.closest('.fan-row').querySelector('.fan-target');
        if (tEl) tEl.innerHTML = 'target <b>' + fmtRpm(f.target) + '</b> · actual <b>' + fmtRpm(fanRpm(f)) + '</b> rpm';
        var bf = document.getElementById('barFan');
        if (bf) bf.querySelector('.sv').textContent = fmtRpm(fanRpm(S.fans[0]));
      });
    });
    var hr = panel.querySelector('#hdrRevert') , fr = panel.querySelector('#fanRevert');
    [hr, fr].forEach(function (b) {
      if (b) b.addEventListener('click', function () { setFansAuto(); renderPanel(false); renderBarIfLive(); });
    });
  }
  function setFansAuto() {
    S.fans.forEach(function (f) { f.mode = 'auto'; });
    S.overrideSince = null;
  }
  function renderBarIfLive() { if (document.getElementById('barHost')) renderBar(); }

  /* ---------------- refresh cadence ----------------
     Everything updates here, every T.time.refreshMs — nothing renders
     between ticks (doc §5.5). The browser timer stands in for the
     native push-update pipeline. */
  function tick(first) {
    if (!first) {
      S.cpu.shift(); S.net.shift();
      S.cpu.push(abnormal() ? 82 + Math.random() * 12 : 9 + Math.random() * 7);
      S.net.push(0.4 + Math.random() * 2.2);
    }
    var cpuV = Math.round(S.cpu[S.cpu.length - 1]) + '%';
    var dnP = rateParts(S.net[S.net.length - 1]);
    var upP = rateParts((120 + Math.random() * 120) / 1000);
    [['vCpu', cpuV], ['barCpu', cpuV], ['vNetD', dnP[0]], ['barNetD', dnP.join(' ')], ['vNetU', upP[0]], ['barNetU', upP.join(' ')],
     ['vGpu', Math.round(abnormal() ? 22 + Math.random() * 8 : 5 + Math.random() * 4) + '%']
    ].forEach(function (p) { var el = document.getElementById(p[0]); if (el) el.textContent = p[1]; });
    var dEl = document.getElementById('vNetD'), uEl = document.getElementById('vNetU');
    if (dEl && dEl.nextElementSibling) dEl.nextElementSibling.textContent = dnP[1];
    if (uEl && uEl.nextElementSibling) uEl.nextElementSibling.textContent = upP[1];
    [['fanL', 0], ['fanR', 1]].forEach(function (p) {
      var el = document.getElementById(p[0]);
      if (el) el.textContent = fmtRpm(fanRpm(S.fans[p[1]])) + ' rpm';
    });
    var panel = document.getElementById('eulPanel');
    if (panel) {
      var sparks = panel.querySelectorAll('.spark');
      drawSpark(sparks[0], S.cpu, 100);
      drawSpark(sparks[1], S.net, 3);
    }
  }

  /* ---------------- rig (doc chrome) ---------------- */
  function wireRig() {
    var sl = document.getElementById('rigWidth');
    if (sl) {
      sl.addEventListener('input', function () {
        S.thirdParty = +sl.value;
        var v = document.getElementById('rigWidthVal');
        if (v) v.textContent = sl.value + ' third-party items';
        renderBar();
      });
    }
    var sc = document.getElementById('rigScenario');
    if (sc) sc.addEventListener('click', function () {
      S.scenario = abnormal() ? 'normal' : 'fan';
      sc.setAttribute('aria-pressed', String(abnormal()));
      if (abnormal()) {
        var n = S.cpu.length;
        S.cpu = S.cpu.map(function (v, i) { return i > n * 0.55 ? 80 + Math.random() * 14 : v; });
      } else {
        S.cpu = S.cpu.map(function () { return 9 + Math.random() * 7; });
      }
      renderBarIfLive();
      if (S.panelOpen || S.mode === 'panel') renderPanel(false);
    });
    var md = document.getElementById('rigMode');
    if (md) md.addEventListener('click', function () {
      S.light = !S.light;
      md.setAttribute('aria-pressed', String(S.light));
      var stage = document.getElementById('panelHost');
      if (stage) stage.classList.toggle('light');
      renderBarIfLive();
      if (S.panelOpen || S.mode === 'panel') renderPanel(false);
    });
  }

  /* ---------------- boot ---------------- */
  document.addEventListener('DOMContentLoaded', function () {
    document.body.classList.add('mode-' + S.mode);
    if (S.mode === 'panel') {
      S.panelOpen = true;
      renderPanel(false);
    } else {
      renderBar();
    }
    wireRig();
    window.addEventListener('resize', fitDisplay);
    /* click-away + Esc dismiss — matches the native panel contract (doc §2.6) */
    document.addEventListener('click', function (e) {
      if (e.target.closest('.rig')) return; /* rig is doc chrome, not click-away */
      if (S.mode !== 'panel' && S.panelOpen) togglePanel();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && S.mode !== 'panel' && S.panelOpen) togglePanel();
    });
    S.timer = setInterval(tick, T.time.refreshMs);
  });
})();
