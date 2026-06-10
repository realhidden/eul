/* eul 2.0 — static doc exhibits: bar states (Exhibit A) + widgets (Exhibit D).
   The live bar rig and the clickable panel live in "eul 2.0 Prototype.html"
   and are embedded in the document as iframes. */
(function () {
  'use strict';

  function eyes(w) {
    return '<svg class="eyes" viewBox="0 0 20 12" width="' + w + '" height="' + Math.round(w * 0.6) + '" aria-hidden="true">'
      + '<circle class="ering" cx="6" cy="6" r="4.2"></circle><circle class="ering er" cx="14" cy="6" r="4.2"></circle>'
      + '<circle class="epup" cx="6" cy="6" r="1.5"></circle><circle class="epup epr" cx="14" cy="6" r="1.5"></circle></svg>';
  }
  function anchor(state) { return '<span class="mi eul-anchor state-' + state + '">' + eyes(18) + '</span>'; }
  function slot(label, value) {
    return '<span class="mi eul-slot"><i class="sl">' + label + '</i><b class="sv tnum">' + value + '</b></span>';
  }
  function netSlot() {
    return '<span class="mi eul-slot eul-net">'
      + '<span class="nrow"><i>↓</i><b>2.4 MB/s</b></span>'
      + '<span class="nrow"><i>↑</i><b>184 KB/s</b></span></span>';
  }
  function wifi() {
    return '<span class="mi sys"><svg viewBox="0 0 16 12" width="15" height="11">'
      + '<path d="M1.6 4.6a9.2 9.2 0 0 1 12.8 0" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"></path>'
      + '<path d="M4.1 7.1a5.6 5.6 0 0 1 7.8 0" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"></path>'
      + '<circle cx="8" cy="9.9" r="1.5" fill="currentColor"></circle></svg></span>';
  }
  function battery() {
    return '<span class="mi sys"><span class="batt"><span class="bcase"><span class="bfill"></span></span><span class="bnub"></span></span></span>';
  }
  function clock() { return '<span class="mi clock">Tue Jun 10&nbsp;&nbsp;9:41 AM</span>'; }
  function gi(kind) { return '<span class="mi"><span class="gi ' + kind + '"></span></span>'; }

  function stripHTML(slots, glyphState) {
    var h = '';
    slots.forEach(function (s) {
      if (s === 'fan') h += slot('FAN', '4,200');
      if (s === 'cpu') h += slot('CPU', '12%');
      if (s === 'mem') h += slot('MEM', '58%');
      if (s === 'net') h += netSlot();
    });
    h += anchor(glyphState);
    return h + gi('circle') + wifi() + battery() + clock();
  }

  function renderStates() {
    var host = document.getElementById('mbStates');
    if (!host) return;
    var states = [
      { n: 'A — Comfortable', d: 'anchor + pinned slots (CPU · NET). Slots are fixed-width; nothing ever shifts.', slots: ['cpu', 'net'], g: 'normal' },
      { n: 'B — Space-tight', d: 'the width governor dropped NET (lowest priority). CPU survives; the bar stays coherent.', slots: ['cpu'], g: 'normal' },
      { n: 'C — Collapse floor', d: 'anchor only. Health + entry point intact — eul never disappears (P2).', slots: [], g: 'normal' },
      { n: 'D — Elevated', d: 'right eye fills amber. Color lives in the anchor only, so it reads at any width.', slots: ['cpu', 'net'], g: 'elevated' },
      { n: 'E — Critical', d: 'both eyes fill red — OS-reported heavy pressure or a nearly-full boot disk.', slots: ['cpu', 'net'], g: 'critical' },
      { n: 'F — Fan override', d: 'manual fan control active: the FAN slot auto-pins, exempt from collapse, until reverted to Auto (§2.7).', slots: ['fan', 'cpu', 'net'], g: 'normal' }
    ];
    var h = '';
    states.forEach(function (s) {
      h += '<div class="mbrow"><div class="mblabel"><b>' + s.n + '</b><span>' + s.d + '</span></div>'
        + '<div class="mbwall dark"><div class="mbbar">' + stripHTML(s.slots, s.g) + '</div></div>'
        + '<div class="mbwall light"><div class="mbbar">' + stripHTML(s.slots, s.g) + '</div></div></div>';
    });
    host.innerHTML = h;
  }

  /* ---------- sparkline ---------- */
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

  /* ---------- Exhibit D: widgets ---------- */
  function widgetSmall(stale) {
    return '<div class="widget small' + (stale ? ' stale' : '') + '">'
      + '<div class="w-head"><span class="t-label">EUL</span><span class="state-normal" style="color:#f4f4f6;">' + eyes(15) + '</span></div>'
      + '<div class="w-verdict">All normal</div>'
      + '<div class="w-stats"><div class="w-stat"><b>12%</b><span>CPU</span></div><div class="w-stat"><b>58%</b><span>MEM</span></div></div>'
      + '<div class="w-stamp w-cap">' + (stale ? 'as of 2 min ago' : '42 s ago') + '</div></div>';
  }
  function widgetMedium() {
    var rows = [['CPU', '12%'], ['MEM', '58%'], ['NET', '↓ 2.4 M']].map(function (r) {
      return '<div class="w-row"><span class="w-l">' + r[0] + '</span>' + sparkSVG() + '<span class="w-v">' + r[1] + '</span></div>';
    }).join('');
    return '<div class="widget medium"><div class="w-head"><span class="t-label">EUL · TRENDS</span><span style="color:#f4f4f6;">' + eyes(15) + '</span></div>'
      + '<div class="w-rows">' + rows + '</div><div class="w-stamp w-cap">38 s ago</div></div>';
  }
  function renderWidgets() {
    var stage = document.getElementById('widgetStage');
    if (!stage) return;
    stage.innerHTML = widgetSmall(false) + widgetMedium() + widgetSmall(true);
    var base = [];
    for (var i = 0; i < 40; i++) base.push(9 + Math.random() * 7);
    var data = [base, base.map(function (v) { return 50 + v; }), base.map(function (v) { return v * 6; })];
    stage.querySelectorAll('.widget.medium .spark').forEach(function (s, i) { drawSpark(s, data[i], 110); });
  }

  window.initMockups = function () {
    renderStates();
    renderWidgets();
  };
})();
