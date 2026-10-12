/* hako: Browse and plugin lists. The c196 engine (PLUGIN_MANAGER_screen.js, trimmed) and this brief's scenes.
   node PLUGIN_BROWSER_screen.js > PLUGIN_BROWSER_MOCK.txt */
const CELLW = 9;
const ROWH = 18;

const BS = {
  rounded: { tl: "╭", tr: "╮", bl: "╰", br: "╯", h: "─", v: "│", lt: "├", rt: "┤", tt: "┬", bt: "┴", x: "┼" },
  plain:   { tl: "┌", tr: "┐", bl: "└", br: "┘", h: "─", v: "│", lt: "├", rt: "┤", tt: "┬", bt: "┴", x: "┼" },
  thick:   { tl: "┏", tr: "┓", bl: "┗", br: "┛", h: "━", v: "┃", lt: "┣", rt: "┫", tt: "┳", bt: "┻", x: "╋" },
  double:  { tl: "╔", tr: "╗", bl: "╚", br: "╝", h: "═", v: "║", lt: "╠", rt: "╣", tt: "╦", bt: "╩", x: "╬" },
  ascii:   { tl: "+", tr: "+", bl: "+", br: "+", h: "-", v: "|", lt: "+", rt: "+", tt: "+", bt: "+", x: "+" },
  none:    { tl: " ", tr: " ", bl: " ", br: " ", h: " ", v: " ", lt: " ", rt: " ", tt: " ", bt: " ", x: " " }
};

const THEMES = {
  default: {
    bg: "#1e1e2e", fg: "#cdd6f4", surface: "#313244",
    border_active: "#89b4fa", border_inactive: "#45475a", border_floating: "#f5c2e7",
    bar_bg: "default", bar_fg: "#cdd6f4", bar_dim: "#6c7086", bar_accent: "#89b4fa", bar_urgent: "#f38ba8",
    mode_fg: "#1e1e2e", mode_bg: "#f38ba8",
    ws_active_fg: "#1e1e2e", ws_active_bg: "#89b4fa", ws_occupied: "#cdd6f4", ws_empty: "#6c7086", ws_urgent: "#f38ba8",
    picker_selected_fg: "#1e1e2e", picker_selected_bg: "#89b4fa",
    toast_fg: "#cdd6f4", toast_bg: "#313244",
    red: "#f38ba8", green: "#a6e3a1", yellow: "#f9e2af", blue: "#89b4fa", magenta: "#cba6f7", cyan: "#94e2d5", gray: "#6c7086", orange: "#fab387"
  },
  matugen: {
    bg: "#151d19", fg: "#dce5df", surface: "#26312b",
    border_active: "#8bd6b4", border_inactive: "#3c4842", border_floating: "#a8cbe0",
    bar_bg: "default", bar_fg: "#dce5df", bar_dim: "#86948c", bar_accent: "#8bd6b4", bar_urgent: "#ffb4ab",
    mode_fg: "#0f1f26", mode_bg: "#a8cbe0",
    ws_active_fg: "#00382a", ws_active_bg: "#8bd6b4", ws_occupied: "#dce5df", ws_empty: "#86948c", ws_urgent: "#ffb4ab",
    picker_selected_fg: "#00382a", picker_selected_bg: "#8bd6b4",
    toast_fg: "#dce5df", toast_bg: "#26312b",
    red: "#ffb4ab", green: "#a3d39c", yellow: "#e8c983", blue: "#9ccaff", magenta: "#d7bde4", cyan: "#8fd0d6", gray: "#86948c", orange: "#f2b88a"
  },
  latte: {
    bg: "#eff1f5", fg: "#4c4f69", surface: "#dce0e8",
    border_active: "#1e66f5", border_inactive: "#bcc0cc", border_floating: "#8839ef",
    bar_bg: "default", bar_fg: "#4c4f69", bar_dim: "#7c7f93", bar_accent: "#1e66f5", bar_urgent: "#d20f39",
    mode_fg: "#eff1f5", mode_bg: "#8839ef",
    ws_active_fg: "#eff1f5", ws_active_bg: "#1e66f5", ws_occupied: "#4c4f69", ws_empty: "#8c8fa1", ws_urgent: "#d20f39",
    picker_selected_fg: "#eff1f5", picker_selected_bg: "#1e66f5",
    toast_fg: "#4c4f69", toast_bg: "#dce0e8",
    red: "#d20f39", green: "#40a02b", yellow: "#df8e1d", blue: "#1e66f5", magenta: "#8839ef", cyan: "#179299", gray: "#8c8fa1", orange: "#fe640b"
  }
};

/* ---------- cells ---------- */

function hexRgb(h) {
  h = h.replace("#", "");
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
}
function rgbHex(r) {
  return "#" + r.map(function (v) { return Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0"); }).join("");
}
function mix(a, b, t) {
  const A = hexRgb(a), B = hexRgb(b);
  return rgbHex([0, 1, 2].map(function (i) { return A[i] + (B[i] - A[i]) * t; }));
}
function res(T, c) {
  if (!c || c === "bg") return T.bg;
  if (c[0] === "#") return c;
  const v = T[c];
  if (v === undefined) return T.fg;
  if (v === "default") return T.bg;
  return v;
}
function len(s) { return Array.from(String(s)).length; }
function trunc(s, n) {
  const a = Array.from(String(s));
  if (a.length <= n) return String(s);
  if (n <= 0) return "";
  return a.slice(0, n - 1).join("") + "…";
}
// A link keeps its host and its end; the middle gives way.
function truncMid(s, n) {
  const a = Array.from(String(s));
  if (a.length <= n) return String(s);
  if (n <= 1) return n === 1 ? "…" : "";
  const head = Math.ceil((n - 1) / 2), tail = n - 1 - head;
  return a.slice(0, head).join("") + "…" + (tail ? a.slice(a.length - tail).join("") : "");
}
function isSafe(ch) {
  const c = ch.codePointAt(0);
  return (c >= 0x20 && c < 0x7f) || (c >= 0x2500 && c <= 0x259f);
}

class Scr {
  constructor(W, H) {
    this.W = W; this.H = H; this.clip = null;
    this.cells = [];
    for (let i = 0; i < W * H; i++) this.cells.push({ ch: " ", fg: "fg", bg: "bg", b: false, it: false, u: false, r: false, f: 0 });
  }
  set(x, y, ch, st) {
    if (x < 0 || y < 0 || x >= this.W || y >= this.H) return;
    const k = this.clip;
    if (k && (x < k.x || x >= k.x + k.w || y < k.y || y >= k.y + k.h)) return;
    const c = this.cells[y * this.W + x];
    st = st || {};
    c.ch = ch;
    if (st.fg !== undefined) c.fg = st.fg;
    if (st.bg !== undefined) c.bg = st.bg;
    c.b = !!st.b; c.it = !!st.it; c.u = !!st.u; c.r = !!st.r; c.f = st.f || 0;
  }
  put(x, y, s, st) {
    const a = Array.from(String(s));
    for (let i = 0; i < a.length; i++) this.set(x + i, y, a[i], st);
    return x + a.length;
  }
  fill(x, y, w, h, st, ch) {
    for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) this.set(xx, yy, ch || " ", st);
  }
  box(x, y, w, h, bs, st) {
    const B = BS[bs];
    for (let i = 1; i < w - 1; i++) { this.set(x + i, y, B.h, st); this.set(x + i, y + h - 1, B.h, st); }
    for (let j = 1; j < h - 1; j++) { this.set(x, y + j, B.v, st); this.set(x + w - 1, y + j, B.v, st); }
    this.set(x, y, B.tl, st); this.set(x + w - 1, y, B.tr, st);
    this.set(x, y + h - 1, B.bl, st); this.set(x + w - 1, y + h - 1, B.br, st);
  }
  // Reverse a cell in place (the mock's way of showing where the pointer is).
  rev(x, y) {
    if (x < 0 || y < 0 || x >= this.W || y >= this.H) return;
    this.cells[y * this.W + x].r = true;
  }
}

function toLines(s, T) {
  const out = [];
  for (let y = 0; y < s.H; y++) {
    const spans = [];
    let cur = null;
    for (let x = 0; x < s.W; x++) {
      const c = s.cells[y * s.W + x];
      const safe = isSafe(c.ch);
      let bg = res(T, c.bg);
      let fg = res(T, c.fg);
      if (c.f) fg = mix(fg, bg, c.f);
      if (c.r) { const t = fg; fg = bg; bg = t; }
      const key = fg + bg + c.b + c.it + c.u;
      if (cur && safe && cur.safe && cur.key === key) { cur.t += c.ch; cur.n++; }
      else { cur = { t: c.ch, n: 1, key: key, safe: safe, fg: fg, bg: bg, b: c.b, it: c.it, u: c.u }; spans.push(cur); }
    }
    out.push({ spans: spans.map(function (p) {
      return { t: p.t, w: p.n * CELLW, fg: p.fg, bg: p.bg, fw: p.b ? "700" : "400", fs: p.it ? "italic" : "normal", td: p.u ? "underline" : "none" };
    }) });
  }
  return out;
}
function toText(s) {
  const out = [];
  for (let y = 0; y < s.H; y++) {
    let row = "";
    for (let x = 0; x < s.W; x++) row += s.cells[y * s.W + x].ch;
    out.push(row);
  }
  return out.join("\n");
}

function wrap(text, w, max) {
  const words = String(text).split(" ");
  const lines = [];
  let cur = "";
  words.forEach(function (wd) {
    if (!cur.length) cur = wd;
    else if (len(cur) + 1 + len(wd) <= w) cur += " " + wd;
    else { lines.push(cur); cur = wd; }
  });
  if (cur.length) lines.push(cur);
  if (lines.length > max) {
    const keep = lines.slice(0, max);
    keep[max - 1] = trunc(keep[max - 1] + " …", w);
    return keep;
  }
  return lines.map(function (l) { return trunc(l, w); });
}

/* ---------- roles ----------
   A plugin names one of four roles for a value, a mark, a badge or a line of
   text; ranma maps them onto the theme. Nothing else is open to it. */

const ROLE = { normal: "toast_fg", dim: "bar_dim", accent: "bar_accent", urgent: "bar_urgent" };
function roleSt(role, sel, strong) {
  role = role || "normal";
  if (sel) return role === "dim" ? { fg: "picker_selected_fg", f: 0.4 } : { fg: "picker_selected_fg", b: role !== "normal" || !!strong };
  return { fg: ROLE[role] || "toast_fg", b: role === "urgent" || !!strong };
}

/* ---------- blocks ----------
   heading  { k:"heading", text, tag?, count? }
   row      { k:"row", id, name, mark?:{t,role}, note?, value?, select?:false, keys?, detail?:[blocks] }
            value: { shape:"text", t, role } | { shape:"choice", v } | { shape:"toggle", v }
                 | { shape:"slider", frac, t } | { shape:"swatch", hex } | { shape:"field", v }
   text     { k:"text", t, role?, strong?, max? }
   facts    { k:"facts", items:[[label, value, {role, strong}?]] }
   progress { k:"progress", label?, frac, num? }
   log      { k:"log", lines:[string | [[text, "hit"|"num"|"strong"]]], n?, at? }
   sep      { k:"sep" }       space { k:"space" } */

function valueSegs(v, CW, sel) {
  const segs = [];
  if (!v) return segs;
  const P = function (t, st) { segs.push([t, st]); };
  const compact = CW < 28, sp = compact ? "" : " ";
  const base = sel ? { fg: "picker_selected_fg" } : { fg: "toast_fg" };
  const dim = sel ? { fg: "picker_selected_fg", f: 0.4 } : { fg: "bar_dim" };
  const acc = sel ? { fg: "picker_selected_fg", b: true } : { fg: "bar_accent" };
  const sh = v.shape || "text";
  if (sh === "text") P(v.t, roleSt(v.role, sel));
  else if (sh === "choice") { P("‹" + sp, acc); P(String(v.v), base); P(sp + "›", acc); }
  else if (sh === "toggle") { P("[" + sp, dim); P(v.v ? "on" : "off", v.v ? Object.assign({}, acc, { b: true }) : base); P(sp + "]", dim); }
  else if (sh === "slider") {
    const sw = CW >= 60 ? 17 : CW >= 40 ? 7 : CW >= 34 ? 5 : 0;
    if (sw) {
      const k = Math.round(v.frac * (sw - 1));
      for (let i = 0; i < sw; i++) {
        if (i < k) P("━", sel ? { fg: "picker_selected_fg" } : { fg: "bar_accent" });
        else if (i === k) P("●", sel ? { fg: "picker_selected_fg", b: true } : { fg: "toast_fg", b: true });
        else P("─", dim);
      }
      P(" ", base);
    }
    if (!compact && len(v.t) < 4) P(" ".repeat(4 - len(v.t)), base);
    P("‹" + sp, acc); P(v.t, base); P(sp + "›", acc);
  } else if (sh === "meter") {
    // NEW: a read-only slider inside a row: what a task is doing, then how far.
    // No arrows (nothing to step). frac nil: no bar, the word and a time.
    const mw = v.frac == null ? 0 : CW >= 60 ? 13 : CW >= 40 ? 7 : CW >= 34 ? 5 : 0;
    P(v.t, sel ? { fg: "picker_selected_fg", b: true } : { fg: "bar_accent" });
    if (v.frac == null && v.time) P(" " + v.time, base);
    if (mw) {
      P(" ", base);
      const k = Math.round(v.frac * (mw - 1));
      for (let i = 0; i < mw; i++) {
        if (i < k) P("━", sel ? { fg: "picker_selected_fg" } : { fg: "bar_accent" });
        else if (i === k) P("●", sel ? { fg: "picker_selected_fg", b: true } : { fg: "toast_fg", b: true });
        else P("─", dim);
      }
      if (CW >= 60) P(" " + String(Math.round(v.frac * 100)).padStart(3) + "%", base);
    }
  } else if (sh === "swatch") {
    P("[" + sp, dim); P("██", { fg: v.hex }); P(" " + v.hex, base); P(sp + "]", dim);
  } else if (sh === "field") {
    const maxIn = Math.max(4, CW - (CW >= 60 ? 44 : 22));
    P("[" + sp, dim); P(trunc("\"" + v.v + "\"", maxIn), base); P(sp + "]", dim);
  }
  return segs;
}

function drawRow(s, x0, y, CW, r, sel, ctx) {
  ctx = ctx || {};
  const wide = CW >= 60;
  const base = sel ? { fg: "picker_selected_fg" } : { fg: "toast_fg" };
  if (sel) s.fill(x0 - 1, y, CW + 2, 1, { bg: "picker_selected_bg" });
  if (r.select !== false) s.put(x0, y, sel ? "›" : " ", { fg: sel ? "picker_selected_fg" : "bar_accent", b: true });
  const segs = valueSegs(r.value, CW, sel);
  const vw = segs.reduce(function (a, sg) { return a + len(sg[0]); }, 0);
  const vx = x0 + CW - vw;
  const mk = r.mark ? r.mark.t : "";
  const mkW = mk ? len(mk) + 1 : 0;
  const showNote = wide && r.note;
  const room = vx - (x0 + 2) - 2 - mkW;
  const nameMax = Math.max(1, showNote ? Math.min(24 - mkW, room) : room);
  const nm = trunc(r.name, nameMax);
  const q = (ctx.query || "").toLowerCase();
  const mi = q ? r.name.toLowerCase().indexOf(q) : -1;
  const na = Array.from(nm);
  for (let i = 0; i < na.length; i++) {
    const hit = mi >= 0 && i >= mi && i < mi + q.length && na[i] !== "…";
    s.set(x0 + 2 + i, y, na[i], Object.assign({}, base, { u: hit, b: hit }));
  }
  if (mk) s.put(x0 + 2 + na.length + 1, y, mk, roleSt(r.mark.role, sel, r.mark.role !== "normal"));
  if (showNote) {
    const nx = x0 + 28, nmax = vx - 2 - nx;
    if (nmax > 3) s.put(nx, y, trunc(r.note, nmax), sel ? { fg: "picker_selected_fg", f: 0.4 } : { fg: "bar_dim" });
  }
  let x = vx;
  segs.forEach(function (sg) { x = s.put(x, y, sg[0], sg[1]); });
}

function drawHead(s, x0, y, CW, h, hch) {
  const cnt = h.count != null ? String(h.count) : "";
  const tagW = h.tag ? len(h.tag) + 1 : 0;
  const nameMax = Math.max(1, CW - tagW - (cnt ? len(cnt) + 1 : 0) - 4);
  let x = s.put(x0, y, trunc(h.text, nameMax), { fg: "bar_accent", b: true });
  if (h.tag) x = s.put(x + 1, y, h.tag, { fg: "bar_dim" });
  const end = cnt ? x0 + CW - len(cnt) - 1 : x0 + CW;
  for (x = x + 1; x < end; x++) s.set(x, y, hch, { fg: "bar_dim" });
  if (cnt) s.put(x0 + CW - len(cnt), y, cnt, { fg: "bar_dim" });
}

// label value · label value: pairs go from the end, then the labels go.
function drawFacts(s, x, y, W, items) {
  const wOf = function (arr, lab) {
    return arr.reduce(function (a, it, i) { return a + (i ? 3 : 0) + (lab && it[0] ? len(it[0]) + 1 : 0) + len(it[1]); }, 0);
  };
  const its = items.slice();
  while (its.length > 1 && wOf(its, true) > W) its.pop();
  const lab = wOf(its, true) <= W;
  let cx = x;
  its.forEach(function (it, i) {
    if (i) cx = s.put(cx, y, " · ", { fg: "bar_dim" });
    if (lab && it[0]) cx = s.put(cx, y, it[0] + " ", { fg: "bar_dim" });
    const o = it[2] || {};
    cx = s.put(cx, y, trunc(it[1], Math.max(1, x + W - cx)), roleSt(o.role, false, o.strong));
  });
}

// The slider without its arrows: label, bar, number. Below 5 cells the bar goes.
function drawProgress(s, x, y, W, b) {
  const lab = b.label || "", num = b.num || "";
  const bw = W - len(lab) - len(num) - (lab ? 1 : 0) - (num ? 1 : 0);
  let cx = x;
  if (lab) cx = s.put(cx, y, trunc(lab, Math.max(1, W - len(num) - 1)), { fg: "toast_fg" }) + 1;
  if (bw >= 5) {
    const k = Math.round(b.frac * (bw - 1));
    for (let i = 0; i < bw; i++) {
      if (i < k) s.set(cx + i, y, "━", { fg: "bar_accent" });
      else if (i === k) s.set(cx + i, y, "●", { fg: "toast_fg", b: true });
      else s.set(cx + i, y, "─", { fg: "bar_dim" });
    }
  }
  if (num) s.put(x + W - len(num), y, num, { fg: "toast_fg" });
}

// A log line is cut on the right, no ellipsis: it is a tail of something longer.
function drawLog(s, x, y, W, ln, hot) {
  const segs = typeof ln === "string" ? [[ln]] : ln;
  const base = hot ? { fg: "toast_fg" } : { fg: "bar_dim" };
  const old = s.clip;
  s.clip = { x: x, y: y, w: Math.max(0, W), h: 1 };
  let cx = x;
  segs.forEach(function (sg) {
    let st = base;
    if (sg[1] === "hit") st = { fg: "toast_fg", b: true, u: true };
    else if (sg[1] === "num") st = { fg: "bar_dim" };
    else if (sg[1] === "strong") st = { fg: "toast_fg", b: true };
    cx = s.put(cx, y, sg[0], st);
  });
  s.clip = old;
}

function logWindow(b, n) {
  const L = b.lines.length;
  n = Math.min(n, L);
  let start = L - n;
  if (b.at != null) start = Math.max(0, Math.min(b.at - Math.floor((n - 1) / 2), L - n));
  return { start: start, n: n };
}

// Blocks to one-row items. ind: 2 in the list (under the names), 0 in the detail.
function layoutBlocks(blocks, CW, ind, ctx) {
  const out = [];
  (blocks || []).forEach(function (b) {
    if (b.k === "heading") out.push({ head: b, draw: function (s, x, y) { drawHead(s, x, y, CW, b, ctx.hch); } });
    else if (b.k === "row") out.push({ row: b, draw: function (s, x, y, on) { drawRow(s, x, y, CW, b, on, ctx); } });
    else if (b.k === "text") wrap(b.t, CW - ind, b.max || 4).forEach(function (ln) {
      out.push({ draw: function (s, x, y) { s.put(x + ind, y, ln, roleSt(b.role, false, b.strong)); } });
    });
    else if (b.k === "facts") out.push({ draw: function (s, x, y) { drawFacts(s, x + ind, y, CW - ind, b.items); } });
    else if (b.k === "progress") out.push({ draw: function (s, x, y) { drawProgress(s, x + ind, y, CW - ind, b); } });
    else if (b.k === "log") {
      const wdw = logWindow(b, b.n || b.lines.length);
      for (let i = 0; i < wdw.n; i++) {
        const j = wdw.start + i;
        out.push({ log: b, draw: function (s, x, y) { drawLog(s, x + ind, y, CW - ind, b.lines[j], b.at === j); } });
      }
    }
    else if (b.k === "sep") out.push({ draw: function (s, x, y) { for (let i = 0; i < CW - ind; i++) s.set(x + ind + i, y, ctx.hch, { fg: "border_inactive" }); } });
    else if (b.k === "space") out.push({ draw: function () {} });
  });
  return out;
}

// The detail area keeps its facts: logs give up lines first.
function fitDetail(blocks, D, CW, ctx) {
  const bl = blocks.map(function (b) { return Object.assign({}, b); });
  let items = layoutBlocks(bl, CW, 0, ctx);
  let guard = 200;
  while (items.length > D && guard--) {
    let big = null;
    bl.forEach(function (b) { if (b.k === "log") { const n = b.n || b.lines.length; if (n > 1 && (!big || n > (big.n || big.lines.length))) big = b; } });
    if (!big) break;
    big.n = Math.min(big.n || big.lines.length, big.lines.length) - 1;
    items = layoutBlocks(bl, CW, 0, ctx);
  }
  return items.slice(0, D);
}

/* ---------- keys ---------- */

const RESERVED = ["↑", "↓", "j", "k", "tab", "/", "esc", "?"];

function valueKeys(v) {
  if (!v) return [];
  if (v.shape === "slider") return [["←→", "step"]];
  if (v.shape === "choice") return [["←→", "choose"]];
  if (v.shape === "toggle") return [["←→", "flip"]];
  if (v.shape === "field") return [["enter", "edit"]];
  return [];
}
function footKeys(S, row, wide, grouped) {
  const k = [];
  if (row) valueKeys(row.value).forEach(function (p) { k.push(p); });
  if (row && row.keys) row.keys.forEach(function (p) { k.push(p); });
  (S.keys || []).forEach(function (p) { k.push(p); });
  if (wide) {
    if (S.filter) k.push(["/", "filter"]);
    if (grouped) k.push(["tab", "next group"]);
    if (row && !(S.keys || []).some(function (p) { return p[0] === "space"; })) k.push(["space", "peek"]);
  }
  return k;
}
// In order, until one does not fit; "? keys" is never dropped.
function putKeys(s, x, y, keys, maxX, noHelp) {
  if (noHelp) {
    // An ask's answers: all of them, no "? keys" (as settings' unsaved question).
    keys.forEach(function (kv, i) {
      if (i) x += 2;
      x = s.put(x, y, kv[0], { fg: kv[2] || "bar_accent", b: true });
      x = s.put(x + 1, y, kv[1], { fg: "bar_dim" });
    });
    return x;
  }
  const tw = 2 + len("? keys");
  let first = true;
  for (let i = 0; i < keys.length; i++) {
    const kv = keys[i];
    const need = (first ? 0 : 2) + len(kv[0]) + 1 + len(kv[1]);
    if (x + need + (first ? tw - 2 : tw) > maxX) break;
    if (!first) x += 2;
    x = s.put(x, y, kv[0], { fg: "bar_accent", b: true });
    x = s.put(x + 1, y, kv[1], { fg: "bar_dim" });
    first = false;
  }
  if (!first) x += 2;
  x = s.put(x, y, "?", { fg: "bar_accent", b: true });
  return s.put(x + 1, y, "keys", { fg: "bar_dim" });
}
function putEdgeKeys(s, xr, y, pairs, bg) {
  const bl = [[" ", 0]];
  pairs.forEach(function (p, i) { if (i) bl.push([" · ", 0]); bl.push([p[0], 1]); bl.push([" " + p[1], 0]); });
  bl.push([" ", 0]);
  let bx = xr - bl.reduce(function (a, p) { return a + len(p[0]); }, 0);
  bl.forEach(function (p) { bx = s.put(bx, y, p[0], p[1] ? { fg: "bar_accent", bg: bg, b: true } : { fg: "bar_dim", bg: bg }); });
}

/* ---------- the screen ---------- */

function bottomKeys(S) {
  if (S.bottom) return S.bottom;
  const b = [];
  if (S.options) b.push(["o", "options"]);
  b.push(["esc", "close"]);
  return b;
}

function drawScreen(s, P) {
  const x = P.x, y = P.y, w = P.w, h = P.h, bs = P.bs, B = BS[bs], S = P.scr;
  const none = bs === "none";
  const bst = { fg: "mode_bg", bg: none ? "toast_bg" : "bg" };
  const rst = { fg: "border_inactive", bg: "toast_bg" };
  const hch = bs === "ascii" ? "-" : "─";
  s.fill(x, y, w, h, { bg: "toast_bg", fg: "toast_fg" });
  s.box(x, y, w, h, bs, bst);
  const heads = S.body.filter(function (b) { return b.k === "heading"; });
  const wide = w >= 90;
  const useIndex = wide && heads.length >= 2;
  const IX = useIndex ? 22 : 0;
  const sepX = x + 1 + IX;
  const x0 = useIndex ? sepX + 2 : x + 2;
  const CW = (x + w - 2) - x0;
  const ctx = { hch: hch, query: S.query || "" };
  const items = layoutBlocks(S.body, CW, 2, ctx);
  let selIdx = -1;
  if (items.some(function (it) { return it.row && it.row.select !== false; })) {
    selIdx = items.findIndex(function (it) { return it.row && it.row.id === S.sel; });
    if (selIdx < 0) selIdx = items.findIndex(function (it) { return it.row && it.row.select !== false; });
  }
  const selRow = selIdx >= 0 ? items[selIdx].row : null;

  const qY = y + 1, r1 = y + 2, listTop = y + 3;
  const footY = y + h - 2, rule2 = footY - 1;
  const body = rule2 - listTop;
  let D = 0;
  if (selRow && selRow.detail && selRow.detail.length) {
    D = Math.min(Math.max(S.detail || 3, Math.floor(body / 5)), Math.floor(body * 0.4));
    if (body - D - 1 < 5) D = 0;
  }
  // NEW (ask): the question takes the detail area, at its fixed height; on a
  // screen too short for a detail it takes all but 3 rows of the list.
  if (S.ask) {
    const want = layoutBlocks(S.ask.blocks, CW, 0, { hch: hch }).length;
    if (!D) D = Math.min(want, Math.max(1, body - 4));
  }
  const rule1 = D ? rule2 - D - 1 : rule2;
  const L = rule1 - listTop;

  const hRule = function (yy, j) {
    for (let i = x + 1; i < x + w - 1; i++) s.set(i, yy, B.h, rst);
    s.set(x, yy, B.lt, bst); s.set(x + w - 1, yy, B.rt, bst);
    if (useIndex && j) s.set(sepX, yy, j, rst);
  };
  hRule(r1, B.x);
  if (D) hRule(rule1, B.bt);
  hRule(rule2, D ? null : B.bt);
  if (useIndex) {
    for (let yy = y + 1; yy < rule1; yy++) if (yy !== r1) s.set(sepX, yy, B.v, rst);
    s.set(sepX, y, B.tt, bst);
  }

  // title, status, bottom keys
  s.put(x + 2, y, " " + S.title + " ", { fg: "toast_fg", bg: bst.bg, b: true });
  if (S.status) {
    const t = " " + S.status.t + " ";
    s.put(x + w - 2 - len(t), y, t, Object.assign(roleSt(S.status.role, false, true), { bg: bst.bg }));
  }
  putEdgeKeys(s, x + w - 2, y + h - 1, bottomKeys(S), bst.bg);

  // the first row: the filter, or the plugin's subtitle; a count on the right
  if (S.input) {
    // NEW (ask with text): the first row is the line being typed, in the filter's place.
    let qx = s.put(x0, qY, S.input.prefix, { fg: "bar_accent", b: true });
    qx = s.put(qx + 1, qY, S.input.text, { fg: "toast_fg", b: true });
    s.set(qx, qY, " ", { bg: "toast_fg" });
  } else if (S.filter) {
    if (S.query) {
      let qx = s.put(x0, qY, "/", { fg: "bar_accent", b: true });
      qx = s.put(qx + 1, qY, S.query, { fg: "toast_fg", b: true });
      if (S.filtering) s.set(qx, qY, " ", { bg: "toast_fg" });
    } else {
      const qx = s.put(x0, qY, "/", { fg: "bar_dim", b: true });
      s.put(qx + 1, qY, "filter", { fg: "bar_dim" });
    }
  } else if (S.subtitle) s.put(x0, qY, trunc(S.subtitle, CW - len(S.count || "") - 2), { fg: "bar_dim" });
  if (S.count) s.put(x0 + CW - len(S.count), qY, S.count, { fg: "bar_dim" });

  // the group index (wide)
  if (useIndex) {
    s.put(x + 2, qY, "Groups", { fg: "bar_dim" });
    let curHead = null;
    for (let i = selIdx; i >= 0; i--) if (items[i].head) { curHead = items[i].head; break; }
    heads.forEach(function (hd, i) {
      const gy = listTop + i;
      const cur = hd === curHead;
      s.put(x + 2, gy, cur ? "›" : " ", { fg: "bar_accent", b: true });
      s.put(x + 4, gy, trunc(hd.text, 13), cur ? { fg: "toast_fg", b: true } : { fg: "toast_fg" });
      const cnt = hd.count != null ? String(hd.count) : "";
      s.put(sepX - 1 - len(cnt), gy, cnt, { fg: "bar_dim" });
    });
  }

  // the list
  let off;
  if (selIdx >= 0) {
    let hi = selIdx;
    while (hi > 0 && !items[hi].head) hi--;
    off = hi;
    if (selIdx - off >= L) off = selIdx - L + 3;
  } else off = S.scroll || 0;
  off = Math.max(0, Math.min(off, Math.max(0, items.length - L)));
  if (!items.length) s.put(x0, listTop, S.empty || "nothing here", { fg: "bar_dim" });
  for (let i = 0; i < L; i++) {
    const it = items[off + i];
    if (!it) break;
    it.draw(s, x0, listTop + i, off + i === selIdx);
  }
  if (items.length > L) {
    const th = Math.max(1, Math.round(L * L / items.length));
    const tp = Math.round(off / (items.length - L) * (L - th));
    const tch = bs === "thick" ? "█" : bs === "ascii" ? "#" : bs === "none" ? "▐" : "┃";
    for (let i = 0; i < th; i++) s.set(x + w - 1, listTop + tp + i, tch, { fg: "toast_fg", bg: bst.bg });
  }

  // the detail of the selected row
  if (D) fitDetail(S.ask ? S.ask.blocks : selRow.detail, D, CW, ctx).forEach(function (it, i) { it.draw(s, x0, rule1 + 1 + i, false); });

  if (S.ask) putKeys(s, x0, footY, S.ask.keys, x0 + CW, true);
  else putKeys(s, x0, footY, footKeys(S, selRow, wide, heads.length >= 2), x0 + CW);

  if (P.help) {
    const ch = 3 + (S.card || []).length + ranmaKeys(S).length;
    drawKeysCard(s, x + Math.floor((w - 40) / 2), ch > h - 4 ? y + 1 : y + 2, S, bs);
  }
  return selRow;
}

/* ---------- the keys card ---------- */

function ranmaKeys(S) {
  if (S.cardRanma) return S.cardRanma;
  const rows = S.body.filter(function (b) { return b.k === "row" && b.select !== false; });
  const k = [[rows.length ? "↑↓ j k" : "↑↓ j k", rows.length ? "move" : "scroll"]];
  if (S.body.filter(function (b) { return b.k === "heading"; }).length >= 2) k.push(["tab", "next group"]);
  if (S.filter) k.push(["/", S.filter === "plugin" ? "search again" : "filter by name"]);
  if (rows.length && !(S.keys || []).some(function (p) { return p[0] === "space"; })) k.push(["space", "peek at the panes"]);
  if (S.options) k.push(["o", S.title + " options"]);
  k.push(["esc", "close"]);
  return k;
}
function drawKeysCard(s, x, y, S, bs) {
  const pk = S.card || [];
  const rk = ranmaKeys(S);
  const w = 40, h = 3 + pk.length + rk.length;
  const hch = bs === "ascii" ? "-" : "─";
  s.fill(x, y, w, h, { bg: "bg", fg: "toast_fg" });
  s.box(x, y, w, h, bs, { fg: "bar_accent", bg: "bg" });
  s.put(x + 2, y, " keys ", { fg: "toast_fg", bg: "bg", b: true });
  let yy = y + 1;
  pk.forEach(function (k) {
    s.put(x + 2, yy, k[0], { fg: "bar_accent", b: true });
    s.put(x + 11, yy, trunc(k[1], w - 13 - (k[2] ? len(k[2]) + 1 : 0)), { fg: "toast_fg" });
    if (k[2]) s.put(x + w - 2 - len(k[2]), yy, k[2], { fg: "bar_dim" });
    yy++;
  });
  let px = s.put(x + 2, yy, "ranma ", { fg: "bar_dim" });
  for (; px < x + w - 2; px++) s.set(px, yy, hch, { fg: "border_inactive" });
  yy++;
  rk.forEach(function (k) {
    s.put(x + 2, yy, k[0], { fg: "bar_accent", b: true });
    s.put(x + 11, yy, k[1], { fg: "toast_fg" });
    yy++;
  });
  s.put(x + 2, y + h - 1, " any key ", { fg: "bar_dim", bg: "bg" });
}

// A pane's title on its top edge (the c138 badges are left out: no pane here has one).
function titleRun(p, room, hch, bfg) {
  return { pieces: [[" " + p.idx + (p.name ? " " + p.name : "") + " ", { fg: bfg, b: !!p.focus }]] };
}
function drawPanes(s, panes, bs) {
  panes.forEach(function (p) {
    const bfg = p.focus ? "border_active" : "border_inactive";
    s.box(p.x, p.y, p.w, p.h, bs, { fg: bfg, bg: "bg" });
    s.clip = { x: p.x + 1, y: p.y + 1, w: p.w - 2, h: p.h - 2 };
    if (p.draw) p.draw(s, p.x + 1, p.y + 1, p.w - 2, p.h - 2);
    s.clip = { x: p.x + 1, y: p.y, w: p.w - 2, h: 1 };
    let cx = p.x + 1;
    titleRun(p, p.w - 3, BS[bs].h, bfg).pieces.forEach(function (pc) { cx = s.put(cx, p.y, pc[0], Object.assign({ bg: "bg" }, pc[1])); });
    s.clip = null;
  });
}
/* ---------- the bar ---------- */

function drawBar(s, y, W, chip, opt) {
  opt = opt || {};
  s.fill(0, y, W, 1, { fg: "bar_fg", bg: "bar_bg" });
  let x = chip ? s.put(0, y, " " + chip + " ", { fg: "mode_fg", bg: "mode_bg", b: true }) + 2 : 0;
  x = s.put(x, y, " 1:code ", { fg: "ws_active_fg", bg: "ws_active_bg", b: true });
  x = s.put(x, y, opt.narrow ? " 2 " : " 2:web ", { fg: "ws_occupied" });
  s.put(x, y, " 3 ", { fg: "ws_empty" });
  const r1 = opt.narrow ? "" : "cpu 12%  mem 41%  ", r2 = "16:36 ";
  if (r1) s.put(W - len(r1) - len(r2), y, r1, { fg: "bar_dim" });
  s.put(W - len(r2), y, r2, { fg: "bar_fg" });
  // A module of the plugin's own, placed first on the right side: pieces of [text, role].
  if (opt.mods && opt.mods.length) {
    const tw = opt.mods.reduce(function (a, m, i) { return a + (i ? 1 : 0) + len(m[0]); }, 0);
    let mx = W - len(r1) - len(r2) - tw - 2;
    opt.mods.forEach(function (m, i) {
      if (i) mx++;
      mx = s.put(mx, y, m[0], roleSt(m[1], false));
    });
  }
}

/* ---------- what is in the panes ---------- */

function segLines(lines, fromTop) {
  return function (s, x, y, w, h) {
    const start = fromTop ? 0 : Math.max(0, lines.length - h);
    for (let i = start; i < lines.length && i - start < h; i++) {
      let cx = x;
      lines[i].forEach(function (sg) { cx = s.put(cx, y + i - start, sg[0], { fg: sg[1] || "fg", b: !!sg[2], u: sg[3] === "u", it: sg[3] === "i" }); });
    }
  };
}
const T_ = function (t, c, b, a) { return [t, c, b, a]; };
function panelW(W) { return W >= 160 ? 96 : W >= 100 ? 56 : W >= 64 ? 44 : W; }

// A plugin screen: the panes laid out over the whole width, the screen floated
// over their right side (no resize), the bar's chip naming it.
function screenScene(W, H, bs, scr, panes, o) {
  o = o || {};
  const s = new Scr(W, H);
  const pw = panelW(W);
  if (pw < W) drawPanes(s, panes, bs);
  drawScreen(s, { x: W - pw, y: 0, w: pw, h: H - 1, bs: bs, scr: scr, help: o.help });
  drawBar(s, H - 1, W, scr.chip, { narrow: W < 64 });
  return s;
}

/* ---------- what is in the panes behind the screen ---------- */

const LUA_KW = /^(local|function|end|return|require|if|then|else|for|in|do|true|false|nil|and|or|not)$/;
function luaLine(src) {
  if (/^\s*--/.test(src)) return [[src, "gray"]];
  const segs = [];
  const re = /(\s+|[A-Za-z_][A-Za-z0-9_]*|\d+|"[^"]*"|.)/g;
  let m;
  while ((m = re.exec(src))) {
    const t = m[0];
    let r = "fg";
    if (/^\s+$/.test(t)) r = "fg";
    else if (LUA_KW.test(t)) r = "magenta";
    else if (/^\d/.test(t)) r = "orange";
    else if (t[0] === "\"") r = "green";
    else if (t === "ranma" || t === "opts") r = "yellow";
    else if (/^[{}()\[\];:,.<>=+\-]$/.test(t)) r = "gray";
    segs.push([t, r]);
  }
  return segs;
}
function nvimLua(file, lines, cur) {
  return function (s, x, y, w, h) {
    for (let i = 0; i < h - 1 && i < lines.length; i++) {
      let cx = s.put(x, y + i, String(i + 1).padStart(3) + " ", { fg: i === cur ? "yellow" : "gray" });
      luaLine(lines[i]).forEach(function (sg) { cx = s.put(cx, y + i, sg[0], { fg: sg[1] }); });
    }
    for (let i = lines.length; i < h - 1; i++) s.put(x, y + i, "~", { fg: "blue" });
    s.fill(x, y + h - 1, w, 1, { bg: "surface" });
    const cx = s.put(x, y + h - 1, " NORMAL ", { fg: "bg", bg: "blue", b: true });
    s.put(cx, y + h - 1, " " + file + " ", { fg: "fg", bg: "surface" });
  };
}
/* ---------- hako: Browse and plugin lists ----------
   Everything below is this brief's: the plugins and lists, the rows they make,
   and one function per scene. The engine above is the c196 handoff's, unchanged. */

const RANMA_NOW = "0.1.0";
const LISTS = {
  off:   { name: "ranma plugins", official: true, n: 38, url: "https://raw.githubusercontent.com/masshirodev/ranma-plugins/main/plugins.json", fetched: "12m ago" },
  yuzu:  { name: "yuzu's plugins", n: 14, url: "https://raw.githubusercontent.com/yuzu-dev/ranma-list/main/list.json", fetched: "12m ago", added: "2 weeks ago" },
  kenji: { name: "kenji's plugins", n: 9, url: "https://kenji.dev/ranma/plugins.json" }
};
const PG = {
  agents:   { repo: "masshirodev/agents.ranma", desc: "Every coding agent in your panes: which are working, which need you.", tags: ["ai", "agents"], needs: ["kizuna"], lists: ["off"] },
  float:    { repo: "masshirodev/float.ranma", desc: "Any pane as a floating window, moved and sized with the mouse.", tags: ["ui", "panes"], ranma: "0.2.0", lists: ["off"] },
  gitbar:   { repo: "masshirodev/gitbar.ranma", desc: "The focused pane's branch, ahead/behind and dirty files, in the bar.", tags: ["git", "bar"], lists: ["off"] },
  lazygit:  { repo: "masshirodev/lazygit.ranma", desc: "lazygit in a popup, opened on the focused pane's repository.", tags: ["git", "popup"], needs: ["lazygit"], lists: ["off"] },
  linkhover:{ repo: "masshirodev/linkhover.ranma", desc: "Hover a link or a path in any pane to see where it goes.", tags: ["navigation", "ui"], lists: ["off"] },
  notes:    { repo: "masshirodev/notes.ranma", desc: "A scratch note for each workspace, kept between sessions.", tags: ["notes"], lists: ["off"] },
  openpath: { repo: "masshirodev/openpath.ranma", desc: "Open the path under the pointer: files in nvim, folders in yazi.", tags: ["navigation", "files"], needs: ["nvim", "yazi"], lists: ["off", "yuzu"] },
  sessions: { repo: "masshirodev/sessions.ranma", desc: "Save each workspace's layout and directories; bring them back after a reboot.", tags: ["sessions"], lists: ["off"] },
  blame:    { repo: "yuzu-dev/blame.ranma", author: "yuzu-dev", desc: "git blame for the line under the pointer, in a tooltip.", tags: ["git"], needs: ["git"], lists: ["yuzu"] },
  tidy:     { repo: "yuzu-dev/tidy.ranma", author: "yuzu-dev", desc: "Closes panes whose program exited, a minute after it did.", tags: ["panes"], lists: ["yuzu"] },
  pomodoro: { repo: "yuzu-dev/pomodoro.ranma", author: "yuzu-dev", desc: "A 25-minute timer in the bar, and a toast when it ends.", tags: ["bar", "time"], lists: ["yuzu"] },
  history:  { repo: "masshirodev/history.ranma", desc: "Search a pane's scrollback by regex and jump to a match.", tags: ["search", "scrollback"], lists: ["off"], installed: "init.lua:4" },
  compose:  { repo: "masshirodev/compose.ranma", desc: "Write a long command or prompt in an editor, then send it to the pane.", tags: ["editing", "ai"], lists: ["off"], installed: "lua/plugins/compose.lua:1" },
  clock:    { repo: "masshirodev/clock.ranma", desc: "A clock for the bar, in any os.date format.", tags: ["bar", "time"], lists: ["off"], installed: "lua/plugins/clock.lua:1" },
  marks:    { repo: "masshirodev/marks.ranma", desc: "Mark a spot in a pane's scrollback and jump back to it.", tags: ["navigation", "scrollback"], lists: ["off"], installed: "lua/plugins/marks.lua:1" }
};
Object.keys(PG).forEach(function (k) {
  const p = PG[k];
  p.id = k;
  p.name = p.repo.split("/")[1];
  p.author = p.author || p.repo.split("/")[0];
  p.ranma = p.ranma || "0.1.0";
  p.needs = p.needs || [];
});
function official(p) { return p.lists.indexOf("off") >= 0; }
function listNames(p) {
  const n = p.lists.map(function (l) { return LISTS[l].name; });
  return n.length === 2 ? n[0] + " and " + n[1] : n.join(", ");
}

// A plugin's detail: what it says, then where it came from and what it needs.
// `lead` comes first (a state the row is in); the description gives up a line for it.
function plugDetail(p, lead) {
  const d = [];
  (lead || []).forEach(function (b) { d.push(b); });
  d.push({ k: "text", t: p.desc, max: lead && lead.length ? 1 : 2 });
  d.push({ k: "facts", items: official(p) ? [["from", listNames(p)]] : [["from", listNames(p)], ["", "nobody reviews it", { role: "accent" }]] });
  const rn = { role: p.ranma !== RANMA_NOW ? "accent" : "normal", strong: p.ranma !== RANMA_NOW };
  d.push({ k: "facts", items: p.needs.length ? [["needs", p.needs.join(", ")], ["ranma", p.ranma + " or newer", rn]] : [["needs", "ranma " + p.ranma + " or newer", rn]] });
  d.push({ k: "facts", items: [["", p.repo], ["by", p.author]] });
  d.push({ k: "facts", items: [["tags", p.tags.join(", ")]] });
  return d;
}

const UNREVIEWED = { t: "unreviewed", role: "accent" };

// P(id, state, o): one plugin row in Browse.
//   avail: not here at all (no value; i installs)   decl: declared, not cloned (○ missing)
//   inst: installed (● installed)                   newer: needs a newer ranma (no i)
function P(id, st, o) {
  o = o || {};
  const p = PG[id];
  const r = { k: "row", id: id, name: p.name, note: p.desc };
  if (!official(p)) r.mark = UNREVIEWED;
  if (st === "avail") {
    r.keys = [["i", "install"]];
    r.detail = plugDetail(p);
  } else if (st === "decl") {
    r.value = { t: "○ missing", role: "normal" };
    r.keys = [["i", "install"]];
    r.detail = plugDetail(p, [{ k: "text", t: "Declared in init.lua:5, not cloned: i installs it.", max: 1 }]);
  } else if (st === "inst") {
    r.value = { t: "● installed", role: "dim" };
    r.keys = [["B", "installed view"]];
    r.detail = plugDetail(p, [{ k: "text", t: "Installed, from " + p.installed + ".", role: "dim", max: 1 }]);
  } else if (st === "newer") {
    r.value = { t: "needs " + p.ranma, role: "dim" };
    r.keys = [];
    r.detail = plugDetail(p, [{ k: "text", t: "Needs ranma " + p.ranma + "; this one is " + RANMA_NOW + ".", role: "accent", max: 1 }]);
  }
  if (o.value) r.value = o.value;
  if (o.mark) r.mark = o.mark;
  if (o.keys) r.keys = o.keys;
  if (o.detail) r.detail = o.detail;
  return r;
}

// L(id, state, o): one list row.
//   ok · fetching · stale (failed, showing last copy) · nocopy (failed, never fetched) · off
function L(id, st, o) {
  o = o || {};
  const l = LISTS[id];
  const r = { k: "row", id: "list:" + id, name: l.name, note: l.url.replace(/^https:\/\//, "") };
  if (l.official) r.mark = { t: "official", role: "dim" };
  const turn = st === "off" ? ["t", "turn on"] : ["t", "turn off"];
  r.keys = l.official ? [turn] : [turn, ["x", "remove"]];
  const url = { k: "facts", items: [["", l.url]] };
  const who = l.official
    ? { k: "text", t: "The official list: reviewed before a plugin goes on it. t turns it off; it can't be removed.", role: "dim", max: 2 }
    : { k: "text", t: "Nobody reviews this list: read a plugin's code before you install it.", role: "accent", max: 2 };
  if (st === "ok") {
    r.value = { t: l.n + " plugins", role: "dim" };
    r.detail = [who, { k: "facts", items: [["", l.n + " plugins"], ["fetched", l.fetched]].concat(l.added ? [["added", l.added]] : []) }, url];
  } else if (st === "fetching") {
    r.value = o.frac == null ? { shape: "meter", t: "fetch", time: o.time || "0:01" } : { shape: "meter", t: "fetch", frac: o.frac };
    r.keys = [];
    r.detail = [{ k: "log", lines: [[["$ curl -fsSL --max-time 10", "strong"]], "  " + l.url.replace(/^https:\/\//, "")] }, { k: "facts", items: [["", "first fetch"], ["then", "every 6 hours"]] }];
  } else if (st === "stale") {
    r.value = { t: "✗ 3 days old", role: "accent" };
    r.detail = [
      { k: "log", lines: [[["curl: (6) Could not resolve host: raw.githubu…", "strong"]]] },
      { k: "text", t: "Showing its copy from 3 days ago (Oct 8, 14 plugins). C tries again.", max: 2 },
      { k: "facts", items: [["tried", "1m ago"], ["fetched", "3 days ago"]] }, url];
  } else if (st === "nocopy") {
    r.value = { t: "✗ no copy", role: "urgent" };
    r.detail = [
      { k: "log", lines: [[["curl: (22) The requested URL returned error: 404", "strong"]]] },
      { k: "text", t: "Never fetched, so none of its plugins show. C tries again; x removes it.", max: 2 },
      { k: "facts", items: [["tried", "1m ago"], ["added", "4m ago"]] }, url];
  } else if (st === "off") {
    r.value = { t: "– off", role: "dim" };
    r.detail = [{ k: "text", t: "Off: its plugins are not in Browse. t turns it on again.", max: 2 }, { k: "facts", items: [["", l.n + " plugins"], ["fetched", l.fetched || "never"]] }, url];
  }
  if (o.value) r.value = o.value;
  if (o.mark) r.mark = o.mark;
  if (o.keys) r.keys = o.keys;
  if (o.detail) r.detail = o.detail;
  return r;
}

const BROWSE_KEYS = [["a", "add list"], ["C", "fetch"]];
const BROWSE_CARD = [
  ["i", "install it"],
  ["t", "turn a list off · on", "list"],
  ["x", "remove a list (asks)", "list"],
  ["a", "add a list: its URL"],
  ["C", "fetch every list again"],
  ["B", "the installed view"],
  ["o", "its options in settings"]
];
const BROWSE_RANMA = [["↑↓ j k", "move"], ["tab", "next group"], ["/", "filter: words or #tag"], ["space", "peek at the panes"], ["esc", "back"]];

// Browse is a view pushed over hako's screen (s:push): esc comes back.
function browseScreen(o) {
  return Object.assign({
    title: "hako", chip: "HAKO", options: true, filter: "plugin", count: "browse · 51 plugins", detail: 6,
    status: null, keys: BROWSE_KEYS, card: BROWSE_CARD, cardRanma: BROWSE_RANMA, bottom: [["o", "options"], ["esc", "back"]]
  }, o);
}

// The usual Browse: the plugins by what they are to you, then the lists.
// A list that needs you (failed, or fetching for the first time) goes first,
// as Failed does in the installed view.
function browseBody(over, o) {
  over = over || {};
  o = o || {};
  const r = function (id, f) { return over[id] || f(); };
  const lists = o.lists || [H("Lists", 2), r("list:off", function () { return L("off", "ok"); }), r("list:yuzu", function () { return L("yuzu", "ok"); })];
  const plugins = [
    H("Not installed", 1), r("notes", function () { return P("notes", "decl"); }),
    H("Available", 45),
    r("agents", function () { return P("agents", "avail"); }),
    r("blame", function () { return P("blame", "avail"); }),
    r("gitbar", function () { return P("gitbar", "avail"); }),
    r("lazygit", function () { return P("lazygit", "avail"); }),
    r("linkhover", function () { return P("linkhover", "avail"); }),
    r("openpath", function () { return P("openpath", "avail"); }),
    r("pomodoro", function () { return P("pomodoro", "avail"); }),
    r("sessions", function () { return P("sessions", "avail"); }),
    r("tidy", function () { return P("tidy", "avail"); }),
    { k: "text", t: "… 36 more, to the end of the alphabet", role: "dim" },
    H("Needs a newer ranma", 1), r("float", function () { return P("float", "newer"); }),
    H("Installed", 4),
    r("clock", function () { return P("clock", "inst"); }),
    r("compose", function () { return P("compose", "inst"); }),
    r("history", function () { return P("history", "inst"); }),
    r("marks", function () { return P("marks", "inst"); })
  ];
  return o.listsFirst ? lists.concat(plugins) : plugins.concat(lists);
}

const HAKO_INIT = [
  "-- ~/.config/ranma/init.lua",
  "require(\"hako\").setup {",
  "  \"masshirodev/hako.ranma\",",
  "  \"masshirodev/history.ranma\",",
  "  \"masshirodev/notes.ranma\",",
  "  { import = \"plugins\" },",
  "}",
  "",
  "ranma.set { border = \"rounded\" }",
  "",
  "ranma.bar {",
  "  left = { \"mode\", \"workspaces\" },",
  "  right = { \"hako\", \"cpu\", \"mem\", \"clock\" },",
  "}"
];
const ZSH_HAKO = segLines([
  [T_("~/.config/ranma", "cyan"), T_(" main", "magenta")],
  [T_("❯ ", "green"), T_("ls lua/plugins")],
  [T_("clock.lua    compose.lua  marks.lua")],
  [T_("~/.config/ranma", "cyan"), T_(" main", "magenta")],
  [T_("❯ ", "green"), T_("█")]
]);
const CARGO_OK2 = segLines([
  [T_("$ ", "gray"), T_("cargo test -q")],
  [T_("running 42 tests")],
  [T_("test layout::dwindle ... "), T_("ok", "green")],
  [T_("test layout::master ... "), T_("ok", "green")],
  [T_("test picker::filter ... "), T_("ok", "green")],
  [T_("")],
  [T_("test result: "), T_("ok", "green"), T_(". 42 passed")],
  [T_("$ ", "gray"), T_("█")]
]);
function hakoPanes(W, H, left) {
  const wA = W >= 160 ? 104 : Math.round(W / 2), hB = Math.floor(H / 2);
  return [
    { x: 0, y: 0, w: wA, h: H, idx: 1, name: "nvim", focus: true, draw: left || nvimLua("init.lua", HAKO_INIT, 4) },
    { x: wA, y: 0, w: W - wA, h: hB, idx: 2, name: "zsh", draw: ZSH_HAKO },
    { x: wA, y: hB, w: W - wA, h: H - hB, idx: 3, name: "cargo", draw: CARGO_OK2 }
  ];
}

/* ---------- the scenes ---------- */

function sBrowse() { return browseScreen({ sel: "agents", body: browseBody() }); }
function sBrowseWide() { return browseScreen({ sel: "openpath", body: browseBody() }); }

// Where B is: hako's own view, a week in, the line at the end of the list.
function sInstalledView() {
  const row = function (id, name, note, value, keys, detail) { return { k: "row", id: id, name: name, note: note, value: value, keys: keys, detail: detail }; };
  const fx = function (br, at, ms, from) { return [{ k: "facts", items: [["branch", br], ["at", at], ["load", ms]] }, { k: "facts", items: [["from", from]] }]; };
  return {
    title: "hako", chip: "HAKO", options: true, filter: "plugin", count: "6 plugins", detail: 6,
    status: null, keys: [["B", "browse"], ["S", "sync"], ["a", "add"], ["C", "check"]], sel: "notes",
    body: [
      H("Not installed", 1),
      row("notes", "notes.ranma", "init.lua:5", { t: "○ missing", role: "normal" }, [["i/I", "install"], ["x", "remove"]],
        [{ k: "text", t: "Declared, not cloned yet: i installs it, and so does the next sync.", max: 2 }, { k: "facts", items: [["", "github.com/masshirodev/notes.ranma"]] }, { k: "facts", items: [["from", "init.lua:5"]] }]),
      H("Installed", 5),
      row("clock", "clock.ranma", "plugins/clock.lua:1", { t: "● 0.2ms", role: "dim" }, [["u/U", "update"], ["l", "log"], ["x", "remove"]], fx("main", "9c1e2aa", "0.2ms", "lua/plugins/clock.lua:1")),
      row("compose", "compose.ranma", "plugins/compose.lua:1", { t: "● 0.3ms", role: "dim" }, [["u/U", "update"], ["l", "log"], ["x", "remove"]], fx("main", "c11a9e0", "0.3ms", "lua/plugins/compose.lua:1")),
      row("hako", "hako.ranma", "init.lua:3", { t: "● 0.6ms", role: "dim" }, [["u/U", "update"], ["l", "log"]], fx("main", "4be1c07", "0.6ms", "init.lua:3")),
      row("history", "history.ranma", "init.lua:4", { t: "● 0.4ms", role: "dim" }, [["u/U", "update"], ["l", "log"], ["x", "remove"]], fx("main", "a3f91c2", "0.4ms", "init.lua:4")),
      row("marks", "marks.ranma", "plugins/marks.lua:1", { t: "● 0.5ms", role: "dim" }, [["u/U", "update"], ["l", "log"], ["x", "remove"]], fx("main", "1f3a9c0", "0.5ms", "lua/plugins/marks.lua:1")),
      { k: "space" },
      { k: "text", t: "B browses 46 more, from 2 lists.", role: "dim" }
    ]
  };
}

// The first time: one list, being fetched; plugins appear as each list lands.
function sFirst() {
  return browseScreen({
    sel: "list:off", count: "browse", status: { t: "fetching 0/1", role: "accent" },
    body: [
      H("Lists", 1), L("off", "fetching", { time: "0:01" }),
      { k: "space" },
      { k: "text", t: "Fetching the official list. Its plugins show here as soon as it lands.", role: "dim", max: 2 }
    ]
  });
}

// Two lists failed: one shows its copy from last time, one has none.
function sFailed() {
  const body = browseBody({}, { listsFirst: true, lists: [H("Lists", 3), L("off", "ok"), L("yuzu", "stale"), L("kenji", "nocopy")] });
  return browseScreen({ sel: "list:yuzu", body: body, status: { t: "1 list failed", role: "urgent" } });
}

function sTwoLists() { return browseScreen({ sel: "openpath", body: browseBody() }); }
function sUnreviewed() { return browseScreen({ sel: "tidy", body: browseBody() }); }
function sNewer() { return browseScreen({ sel: "float", body: browseBody() }); }

// /#git: the lists go while a filter stands; the sections stay.
function sFilter() {
  return browseScreen({
    sel: "gitbar", query: "#git", count: "browse · 3 of 51",
    body: [
      H("Available", 3), P("blame", "avail"), P("gitbar", "avail"), P("lazygit", "avail")
    ]
  });
}
function sNoMatch() {
  return browseScreen({
    query: "gti", filtering: true, count: "browse · 0 of 51",
    body: [
      { k: "text", t: "No plugin matches gti.", strong: true },
      { k: "space" },
      { k: "text", t: "Words match names, descriptions and authors; #tag matches a tag:", role: "dim", max: 2 },
      { k: "text", t: "#git #ai #ui #navigation #files #bar #panes #search #sessions #time", role: "accent", max: 3 }
    ]
  });
}

function sAllOff() {
  return browseScreen({
    sel: "list:off", count: "browse · 0 plugins",
    body: [
      H("Lists", 2), L("off", "off"), L("yuzu", "off"),
      { k: "space" },
      { k: "text", t: "Every list is off: nothing to browse. t turns one on.", role: "dim", max: 2 }
    ]
  });
}

// a: the URL typed in the filter's place.
function sAddUrl() {
  return browseScreen({
    sel: "list:yuzu", body: browseBody(), count: "", input: { prefix: "+", text: "https://kenji.dev/ranma/plugins.json" },
    status: { t: "add list", role: "accent" },
    ask: {
      blocks: [
        { k: "text", t: "A list's URL: one JSON file.", strong: true },
        { k: "text", t: "enter fetches it and shows what it holds; nothing is added yet.", role: "dim", max: 2 },
        { k: "facts", items: [["then writes", "hako-lists.json"]] },
        { k: "space" }
      ],
      keys: [["enter", "fetch"], ["esc", "cancel"], ["ctrl+u", "clear"]]
    } });
}

// The ask, once the list is fetched: needs a deliberate y.
function sAddAsk() {
  return browseScreen({
    sel: "list:yuzu", body: browseBody(), status: { t: "add list?", role: "urgent" },
    ask: {
      blocks: [
        { k: "text", t: "Add the list kenji's plugins?", role: "urgent", strong: true },
        { k: "facts", items: [["", "9 plugins"], ["", "kenji.dev/ranma/plugins.json"]] },
        { k: "text", t: "Nobody reviews this list. Its plugins are Lua that runs as you: they can read your files and run any program. Add it only if you trust who keeps it.", max: 4 }
      ],
      keys: [["y", "add it", "bar_urgent"], ["esc", "cancel"]]
    } });
}

function sRemoveList() {
  const body = browseBody({ "list:yuzu": L("yuzu", "ok", { mark: { t: "deletes", role: "urgent" } }) });
  return browseScreen({
    sel: "list:yuzu", body: body, status: { t: "remove?", role: "urgent" },
    ask: {
      blocks: [
        { k: "text", t: "Remove yuzu's plugins?", role: "urgent", strong: true },
        { k: "text", t: "Its 14 plugins leave Browse. What you installed from it stays installed, and updates from its own repository.", max: 3 },
        { k: "facts", items: [["edits", "hako-lists.json"]] }
      ],
      keys: [["y", "remove", "bar_urgent"], ["esc", "keep it"]]
    } });
}

// i on agents.ranma: the spec file is written, ranma reloads, hako comes back
// to Browse on the row, and the clone runs there.
function sInstall() {
  const p = PG.agents;
  const row = P("agents", "avail", {
    value: { shape: "meter", t: "clone", frac: 0.45 }, keys: [["enter", "open"]],
    mark: { t: "new", role: "accent" },
    detail: [
      { k: "log", lines: ["Cloning into '.part-agents.ranma'...", "remote: Enumerating objects: 214, done.", "Receiving objects:  45% (97/214)"] },
      { k: "facts", items: [["needs", "kizuna"]] }, { k: "facts", items: [["", "github.com/" + p.repo]] },
      { k: "facts", items: [["from", "lua/plugins/agents.lua:1"]] }
    ]
  });
  return browseScreen({ sel: "agents", body: browseBody({ agents: row }), status: { t: "installing 1/1", role: "accent" } });
}

const AGENTS_LUA = [
  "-- lua/plugins/agents.lua",
  "-- written by hako, from ranma plugins;",
  "-- yours to edit",
  "return {",
  "  \"masshirodev/agents.ranma\",",
  "}"
];

const SCENES = [
  { id: "browse80", title: "Browse · 80×24", W: 80, H: 24 },
  { id: "browse200", title: "Browse · 200×50", W: 200, H: 50 },
  { id: "keys80", title: "? keys in Browse · 80×24", W: 80, H: 24 },
  { id: "installed80", title: "the installed view: where B is · 80×24", W: 80, H: 24 },
  { id: "first80", title: "the first open: fetching the lists · 80×24", W: 80, H: 24 },
  { id: "failed80", title: "lists that could not be fetched · 80×24", W: 80, H: 24 },
  { id: "twolists80", title: "one plugin, two lists · 80×24", W: 80, H: 24 },
  { id: "unreviewed80", title: "a plugin from a list nobody reviews · 80×24", W: 80, H: 24 },
  { id: "newer80", title: "needs a newer ranma · 80×24", W: 80, H: 24 },
  { id: "install80", title: "i: installing from Browse · 80×24", W: 80, H: 24 },
  { id: "filter80", title: "/#git: a tag · 80×24", W: 80, H: 24 },
  { id: "nomatch80", title: "/gti: nothing matches · 80×24", W: 80, H: 24 },
  { id: "alloff80", title: "every list turned off · 80×24", W: 80, H: 24 },
  { id: "addurl80", title: "a: typing a list's URL · 80×24", W: 80, H: 24 },
  { id: "addask80", title: "a: the ask before adding · 80×24", W: 80, H: 24 },
  { id: "remove80", title: "x: removing a list · 80×24", W: 80, H: 24 }
];

function buildScene(id, bs) {
  bs = BS[bs] ? bs : "rounded";
  const Pn = function (left) { return hakoPanes(80, 23, left); };
  if (id === "browse200") return screenScene(200, 50, bs, sBrowseWide(), hakoPanes(200, 49));
  if (id === "keys80") return screenScene(80, 24, bs, sBrowse(), Pn(), { help: true });
  if (id === "installed80") return screenScene(80, 24, bs, sInstalledView(), Pn());
  if (id === "first80") return screenScene(80, 24, bs, sFirst(), Pn());
  if (id === "failed80") return screenScene(80, 24, bs, sFailed(), Pn());
  if (id === "twolists80") return screenScene(80, 24, bs, sTwoLists(), Pn());
  if (id === "unreviewed80") return screenScene(80, 24, bs, sUnreviewed(), Pn());
  if (id === "newer80") return screenScene(80, 24, bs, sNewer(), Pn());
  if (id === "install80") return screenScene(80, 24, bs, sInstall(), Pn(nvimLua("agents.lua", AGENTS_LUA, 4)));
  if (id === "filter80") return screenScene(80, 24, bs, sFilter(), Pn());
  if (id === "nomatch80") return screenScene(80, 24, bs, sNoMatch(), Pn());
  if (id === "alloff80") return screenScene(80, 24, bs, sAllOff(), Pn());
  if (id === "addurl80") return screenScene(80, 24, bs, sAddUrl(), Pn());
  if (id === "addask80") return screenScene(80, 24, bs, sAddAsk(), Pn());
  if (id === "remove80") return screenScene(80, 24, bs, sRemoveList(), Pn());
  return screenScene(80, 24, bs, sBrowse(), Pn());
}
function H(text, n) { return { k: "heading", text: text, count: n }; }

if (typeof module !== "undefined" && require.main === module) {
  const out = ["# hako's Browse and plugin lists, cell for cell (PLUGIN_BROWSER_screen.js, default theme)."];
  SCENES.forEach(function (sc) {
    out.push("## " + sc.title + " · rounded");
    out.push(toText(buildScene(sc.id, "rounded")).split("\n").map(function (l) { return l.replace(/ +$/, ""); }).join("\n"));
  });
  console.log(out.join("\n"));
}
