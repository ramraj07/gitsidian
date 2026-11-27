#!/usr/bin/env node
// Preview a *.gitsidian.lock file without a phone.
//
//   node tools/lock-preview.mjs Focus.gitsidian.lock                 -> writes Focus.lock-preview.html
//   node tools/lock-preview.mjs Focus.gitsidian.lock --png out.png   -> also screenshots it (needs Playwright)
//   node tools/lock-preview.mjs Focus.gitsidian.lock --json          -> prints what each size built
//
// It runs the script three times (gitsidian.family = rectangular, circular, inline) with the same
// API and limits as the app, then draws each size at its real point size on a dark Lock Screen, in
// one tint, plus a 3x zoom. It also warns about things the phone can't do (SVG features the
// renderer skips, empty layouts, text that won't fit).
//
// Approximate on purpose: fonts are the browser's system font, and SF Symbols show as a labelled
// placeholder (browsers can't draw them). Layout, sizes, rows and SVG/canvas drawings match.

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { createRequire } from "node:module";

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith("--") && !isFlagValue(a));
function isFlagValue(a) {
  const i = args.indexOf(a);
  return i > 0 && ["--png", "--out", "-o"].includes(args[i - 1]);
}
function flag(name) {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}
if (!file) {
  console.error("usage: node tools/lock-preview.mjs <file.gitsidian.lock> [--out preview.html] [--png preview.png] [--json]");
  process.exit(2);
}
const source = fs.readFileSync(file, "utf8");
const FAMILIES = ["rectangular", "circular", "inline"];
const SIZE = { circular: [76, 76], rectangular: [172, 76], inline: [234, 22] };
const ROW_H = 24, MAX_ROWS = 3;
const warnings = new Set();

// ---------------------------------------------------------------- runtime (mirrors LockBridge.swift)

class ScriptError extends Error {}
const fail = (m) => { throw new ScriptError(m); };
const str = (v) => (v === undefined || v === null ? undefined : typeof v === "string" ? v : typeof v === "number" || typeof v === "boolean" ? String(v) : undefined);
const opt = (o, k) => { const s = o && typeof o === "object" ? str(o[k]) : undefined; return s === "" ? undefined : s; };
const num = (o, k) => (o && typeof o === "object" && typeof o[k] === "number" && isFinite(o[k]) ? o[k] : undefined);
function date(v) {
  if (Object.prototype.toString.call(v) === "[object Date]") return new Date(v.getTime());
  if (typeof v === "number") return new Date(v);
  if (typeof v === "string") { const d = new Date(/^\d{4}-\d{2}-\d{2}$/.test(v) ? v + "T00:00:00Z" : v); return isNaN(d) ? undefined : d; }
  return undefined;
}
function gauge(value, o) {
  const g = { value: isFinite(value) ? value : 0, min: num(o, "min") ?? 0, max: num(o, "max") ?? 1 };
  if (g.max <= g.min) g.max = g.min + 1;
  g.value = Math.min(Math.max(g.value, g.min), g.max);
  const center = { text: opt(o, "center"), symbol: opt(o, "symbol") };
  if (center.text || center.symbol) g.center = center;
  for (const k of ["label", "minLabel", "maxLabel"]) if (opt(o, k)) g[k] = opt(o, k);
  return g;
}
function picture(kind, payload, box) {
  if (kind === "svg") {
    const s = str(payload);
    if (!s) fail("svg(): expected an SVG string");
    return { kind: "svg", markup: s, ...svgSize(s, box) };
  }
  if (typeof payload !== "function") fail("canvas(): expected a draw function (ctx => …)");
  const ops = [];
  payload(recordingContext(ops));
  return { kind: "canvas", ops, width: box[0], height: box[1] };
}

function circularBuilder(out) {
  const set = (name, f) => { if (out.face) fail(`circular.${name}(): a circular widget shows one thing, and one is already set`); out.face = f; };
  return {
    ring: (v, o) => set("ring", { type: "ring", ...gauge(v, o) }),
    gauge: (v, o) => set("gauge", { type: "gauge", ...gauge(v, o) }),
    timeRing: (s, e, o) => {
      const a = date(s), b = date(e);
      if (!a || !b) fail("circular.timeRing(): expected two dates (ISO-8601 string or Date)");
      set("timeRing", { type: "timeRing", start: a < b ? a : b, end: a < b ? b : a, center: { text: opt(o, "center"), symbol: opt(o, "symbol") } });
    },
    number: (t, o) => { if (str(t) === undefined) fail("circular.number(): expected text or a number"); set("number", { type: "number", text: str(t), caption: opt(o, "caption"), symbol: opt(o, "symbol") }); },
    symbol: (n, o) => { if (!str(n)) fail("circular.symbol(): expected an SF Symbol name"); set("symbol", { type: "symbol", name: str(n), caption: opt(o, "caption") }); },
    countdown: (d, o) => { const x = date(d); if (!x) fail("circular.countdown(): expected a date"); set("countdown", { type: "countdown", date: x, caption: opt(o, "caption") }); },
    svg: (m) => set("svg", { type: "picture", ...picture("svg", m, SIZE.circular) }),
    canvas: (fn) => set("canvas", { type: "picture", ...picture("canvas", fn, SIZE.circular) }),
  };
}

function rectangularBuilder(rows) {
  const add = (name, r) => { if (rows.length >= MAX_ROWS) fail(`rectangular.${name}(): a rectangular widget fits ${MAX_ROWS} rows; pick what matters most`); rows.push(r); };
  const box = (o) => [SIZE.rectangular[0], num(o, "height") !== undefined ? Math.min(Math.max(num(o, "height"), 8), 76) : rows.length === 0 ? 76 : ROW_H];
  return {
    title: (t, o) => add("title", { type: "title", text: str(t) ?? "", symbol: opt(o, "symbol") }),
    line: (t, o) => add("line", { type: "line", text: str(t) ?? "", symbol: opt(o, "symbol"), trailing: opt(o, "trailing"), mono: !!(o && o.mono) }),
    bar: (v, o) => add("bar", { type: "bar", ...gauge(v, o) }),
    timeBar: (s, e, o) => {
      const a = date(s), b = date(e);
      if (!a || !b) fail("rectangular.timeBar(): expected two dates (ISO-8601 string or Date)");
      add("timeBar", { type: "timeBar", start: a < b ? a : b, end: a < b ? b : a, label: opt(o, "label") });
    },
    countdown: (d, o) => { const x = date(d); if (!x) fail("rectangular.countdown(): expected a date"); add("countdown", { type: "countdown", date: x, label: opt(o, "label") }); },
    relative: (d, o) => { const x = date(d); if (!x) fail("rectangular.relative(): expected a date"); add("relative", { type: "relative", date: x, label: opt(o, "label") }); },
    sparkline: (vals, o) => {
      if (!Array.isArray(vals)) fail("rectangular.sparkline(): expected an array of numbers");
      add("sparkline", { type: "sparkline", values: vals.slice(0, 200).filter((v) => typeof v === "number" && isFinite(v)), chart: ["bar", "line", "area"].includes(opt(o, "type")) ? opt(o, "type") : "line" });
    },
    svg: (m, o) => add("svg", { type: "picture", ...picture("svg", m, box(o)) }),
    canvas: (fn, o) => add("canvas", { type: "picture", ...picture("canvas", fn, box(o)) }),
  };
}

function inlineBuilder(out) {
  const set = (name, l) => { if (out.line) fail(`inline.${name}(): an inline widget is one line, and it is already set`); out.line = l; };
  return {
    text: (t, o) => set("text", { text: str(t) ?? "", symbol: opt(o, "symbol") }),
    countdown: (d, o) => { const x = date(d); if (!x) fail("inline.countdown(): expected a date"); set("countdown", { text: opt(o, "text") ?? "", symbol: opt(o, "symbol"), date: x, style: "timer" }); },
    relative: (d, o) => { const x = date(d); if (!x) fail("inline.relative(): expected a date"); set("relative", { text: opt(o, "text") ?? "", symbol: opt(o, "symbol"), date: x, style: "relative" }); },
  };
}

function runFamily(family) {
  const result = { circular: undefined, rectangular: undefined, inline: undefined, refreshAfter: undefined };
  let lockCalled = false;
  const lock = {
    circular(fn) { if (typeof fn !== "function") fail("circular(): expected a builder function, e.g. lock.circular(c => …)"); const o = {}; fn(circularBuilder(o)); result.circular = o.face; },
    rectangular(fn) { if (typeof fn !== "function") fail("rectangular(): expected a builder function, e.g. lock.rectangular(r => …)"); const rows = []; fn(rectangularBuilder(rows)); result.rectangular = rows; },
    inline(fn) { if (typeof fn !== "function") fail("inline(): expected a builder function, e.g. lock.inline(i => …)"); const o = {}; fn(inlineBuilder(o)); result.inline = o.line; },
    refreshAfter(m) { if (isFinite(m)) result.refreshAfter = Math.min(Math.max(m, 5), 1440); },
  };
  const gitsidian = {
    lockScreen() { lockCalled = true; return lock; },
    widget() { fail("This is a .gitsidian.lock file: build it with gitsidian.lockScreen(), not gitsidian.widget()"); },
    note: (p) => "gitsidian://open?path=" + encodeURIComponent(String(p ?? "")),
    family, path: path.basename(file), repo: "owner/vault", branch: "main",
  };
  const sandbox = { gitsidian, kondai: gitsidian, console: { log() {}, info() {}, warn() {}, error() {}, debug() {} } };
  try {
    vm.runInNewContext(source, sandbox, { filename: path.basename(file), timeout: 2000 });
    if (!lockCalled) fail("A .gitsidian.lock file builds its widget with gitsidian.lockScreen()");
    return { ok: true, program: result };
  } catch (e) {
    const line = (e.stack || "").match(new RegExp(path.basename(file).replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ":(\\d+)"));
    return { ok: false, error: (line ? `line ${line[1]}: ` : "") + (e.message || String(e)) };
  }
}

// ---------------------------------------------------------------- canvas recording / SVG checks

function recordingContext(ops) {
  let gradients = 0;
  const target = {};
  return new Proxy(target, {
    set(_, k, v) {
      if (v && v.__gradient !== undefined) ops.push(["set", k, { gradient: v.__gradient }]);
      else ops.push(["set", k, v]);
      return true;
    },
    get(_, k) {
      if (k === "createLinearGradient") return (...a) => { const id = gradients++; ops.push(["gradient", id, a]); return { __gradient: id, addColorStop: (o, c) => ops.push(["stop", id, o, c]) }; };
      return (...a) => ops.push(["call", k, a]);
    },
  });
}

function svgSize(markup, box) {
  const vb = (markup.match(/viewBox\s*=\s*["']([^"']+)["']/) || [])[1];
  let w = 100, h = 100;
  if (vb) { const n = vb.trim().split(/[\s,]+/).map(Number); if (n.length === 4 && n[2] > 0 && n[3] > 0) { w = n[2]; h = n[3]; } }
  else {
    const W = parseFloat((markup.match(/<svg[^>]*\swidth\s*=\s*["']([\d.]+)/) || [])[1]);
    const H = parseFloat((markup.match(/<svg[^>]*\sheight\s*=\s*["']([\d.]+)/) || [])[1]);
    if (W > 0) w = W; if (H > 0) h = H;
  }
  const k = Math.min(box[0] / w, box[1] / h);
  checkSvg(markup);
  return { width: w * k, height: h * k };
}

function checkSvg(markup) {
  const unsupported = ["linearGradient", "radialGradient", "pattern", "mask", "clipPath", "filter", "use", "image", "foreignObject", "style", "textPath", "marker"];
  for (const tag of unsupported) if (new RegExp(`<\\s*${tag}[\\s>/]`).test(markup)) warnings.add(`SVG <${tag}> isn't supported on the phone and is skipped.`);
  if (/url\(#/.test(markup)) warnings.add("SVG fill/stroke url(#…) (gradients, patterns) isn't supported; it draws nothing on the phone.");
  if (/(fill|stroke)\s*=\s*["']#(000|000000)["']|(fill|stroke)\s*:\s*#(000|000000)\b|["']black["']/.test(markup)) warnings.add("SVG uses black, which is invisible on the Lock Screen (it tints by brightness). Use white with opacity.");
  if (!/^\s*(<\?xml[^>]*>\s*)?<svg[\s>]/.test(markup)) warnings.add("The SVG markup must start with <svg>.");
}

// ---------------------------------------------------------------- HTML

const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const sym = (name, size = "1em") => name ? `<span class="sym" style="width:${size};height:${size}" title="SF Symbol: ${esc(name)}">${esc(name.split(".")[0].slice(0, 2))}</span>` : "";
const symbolsUsed = new Set();
const useSym = (n, size) => { if (n) symbolsUsed.add(n); return sym(n, size); };
const now = new Date();
function timer(d) {
  let s = Math.abs(Math.round((d - now) / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60); s %= 60;
  return (h ? `${h}:${String(m).padStart(2, "0")}` : `${m}`) + `:${String(s).padStart(2, "0")}`;
}
function relative(d) {
  const diff = (d - now) / 60000, a = Math.abs(diff);
  if (a < 1) return "now";
  const [v, u] = a < 60 ? [a, "min"] : a < 1440 ? [a / 60, "hr"] : a < 10080 ? [a / 1440, "day"] : [a / 10080, "wk"];
  const t = `${Math.round(v)} ${u}${u === "day" || u === "wk" ? (Math.round(v) === 1 ? "" : "s") : ""}`;
  return diff > 0 ? `in ${t}` : `${t} ago`;
}


function svgPicture(p, align) {
  let m = p.markup.replace(/^\s*<\?xml[^>]*>\s*/, "");
  m = m.replace(/<svg\b([^>]*)>/, (all, attrs) => {
    let a = attrs.replace(/\s(width|height)\s*=\s*["'][^"']*["']/g, "");
    if (!/\sfill\s*=/.test(a)) a += ' fill="white"';
    if (!/\scolor\s*=/.test(a)) a += ' color="white"';
    return `<svg${a} width="${p.width}" height="${p.height}">`;
  });
  return `<div class="pic" style="justify-content:${align}">${m}</div>`;
}
let canvasId = 0;
const canvases = [];
function canvasPicture(p, align) {
  const id = "cv" + canvasId++;
  canvases.push({ id, ops: p.ops, w: p.width, h: p.height });
  return `<div class="pic" style="justify-content:${align}"><canvas id="${id}" class="cv" width="${p.width * 3}" height="${p.height * 3}" style="width:${p.width}px;height:${p.height}px"></canvas></div>`;
}
const pictureHTML = (p, align) => (p.kind === "svg" ? svgPicture(p, align) : canvasPicture(p, align));

function ringSVG(frac, open, track = 0.25) {
  const r = 32, c = 2 * Math.PI * r, span = open ? 0.75 : 1;
  const rot = open ? 135 : -90;
  return `<svg class="ring" viewBox="0 0 76 76"><g transform="rotate(${rot} 38 38)">
    <circle cx="38" cy="38" r="${r}" fill="none" stroke="white" stroke-opacity="${track}" stroke-width="6" stroke-linecap="round" stroke-dasharray="${c * span} ${c}"/>
    <circle cx="38" cy="38" r="${r}" fill="none" stroke="white" stroke-width="6" stroke-linecap="round" stroke-dasharray="${c * span * frac} ${c}"/></g></svg>`;
}
const center = (l, caption) => !l && !caption ? "" : `<div class="center">${l?.symbol ? useSym(l.symbol, l.text ? "11px" : "18px") : ""}${l?.text ? `<b>${esc(l.text)}</b>` : ""}${caption ? `<span class="gcap">${esc(caption)}</span>` : ""}</div>`;

function circularHTML(f) {
  if (!f) return `<div class="circ bg">${useSym("lock", "26px")}</div>`;
  const frac = (g) => (g.value - g.min) / (g.max - g.min);
  switch (f.type) {
    case "ring": return `<div class="circ">${ringSVG(frac(f), false)}${center(f.center, f.label)}</div>`;
    case "gauge": return `<div class="circ">${ringSVG(frac(f), true)}${center(f.center)}<div class="mm"><span>${esc(f.minLabel ?? "")}</span><span>${esc(f.maxLabel ?? "")}</span></div></div>`;
    case "timeRing": { const fr = Math.min(Math.max((now - f.start) / (f.end - f.start), 0), 1); return `<div class="circ">${ringSVG(fr, false)}${center(f.center.text || f.center.symbol ? f.center : null)}</div>`; }
    case "number": return `<div class="circ bg col">${useSym(f.symbol, "12px")}<div class="num">${esc(f.text)}</div>${f.caption ? `<div class="cap">${esc(f.caption)}</div>` : ""}</div>`;
    case "symbol": return `<div class="circ bg col">${useSym(f.name, f.caption ? "24px" : "30px")}${f.caption ? `<div class="cap">${esc(f.caption)}</div>` : ""}</div>`;
    case "countdown": return `<div class="circ bg col"><div class="cd">${timer(f.date)}</div>${f.caption ? `<div class="cap">${esc(f.caption)}</div>` : ""}</div>`;
    case "picture": return `<div class="circ bg">${pictureHTML(f, "center")}</div>`;
  }
}

function sparkSVG(values, type, w = 172, h = 22) {
  if (!values.length) return "";
  const lo = Math.min(...values, 0), hi = Math.max(...values), span = hi - lo || 1;
  const x = (i) => (values.length === 1 ? w / 2 : (i / (values.length - 1)) * w), y = (v) => h - ((v - lo) / span) * h;
  if (type === "bar") { const bw = w / values.length; return `<svg width="${w}" height="${h}">${values.map((v, i) => `<rect x="${i * bw + 1}" y="${y(v)}" width="${bw - 2}" height="${h - y(v)}" fill="white"/>`).join("")}</svg>`; }
  const pts = values.map((v, i) => `${x(i)},${y(v)}`).join(" ");
  return `<svg width="${w}" height="${h}">${type === "area" ? `<polygon points="0,${h} ${pts} ${w},${h}" fill="white" opacity="0.4"/>` : ""}<polyline points="${pts}" fill="none" stroke="white" stroke-width="2"/></svg>`;
}

function rectangularHTML(rows) {
  if (!rows || !rows.length) return `<div class="rect"><div class="title">No rectangular layout</div><div class="small">Add lock.rectangular(r =&gt; …)</div></div>`;
  const bar = (frac, label, lo, hi) => `<div class="barrow">${label ? `<div class="small">${esc(label)}</div>` : ""}<div class="barline">${lo ? `<span class="tiny">${esc(lo)}</span>` : ""}<div class="bar"><i style="width:${frac * 100}%"></i></div>${hi ? `<span class="tiny">${esc(hi)}</span>` : ""}</div></div>`;
  return `<div class="rect">${rows.map((r) => {
    switch (r.type) {
      case "title": return `<div class="title">${useSym(r.symbol)}${esc(r.text)}</div>`;
      case "line": return `<div class="line${r.mono ? " mono" : ""}">${useSym(r.symbol, "12px")}<span class="grow">${esc(r.text)}</span>${r.trailing ? `<span class="small dim">${esc(r.trailing)}</span>` : ""}</div>`;
      case "bar": return bar((r.value - r.min) / (r.max - r.min), r.label, r.minLabel, r.maxLabel);
      case "timeBar": return bar(Math.min(Math.max((now - r.start) / (r.end - r.start), 0), 1), r.label);
      case "countdown": return `<div class="line"><span class="grow">${esc(r.label ?? "")}</span><span class="mono">${timer(r.date)}</span></div>`;
      case "relative": return `<div class="line"><span class="grow">${esc(r.label ?? "")}</span><span>${relative(r.date)}</span></div>`;
      case "sparkline": return `<div class="spark">${sparkSVG(r.values, r.chart, 172, rows.length === 1 ? 70 : 22)}</div>`;
      case "picture": return pictureHTML(r, "flex-start");
    }
  }).join("")}</div>`;
}

function inlineHTML(l) {
  if (!l) return `<div class="inline">${useSym("lock")} No inline layout</div>`;
  const t = l.date ? `${esc(l.text)}${l.text ? " " : ""}${l.style === "timer" ? timer(l.date) : relative(l.date)}` : esc(l.text);
  return `<div class="inline">${useSym(l.symbol)}${t}</div>`;
}

// ---------------------------------------------------------------- run

const runs = Object.fromEntries(FAMILIES.map((f) => [f, runFamily(f)]));
const errors = [...new Set(FAMILIES.filter((f) => !runs[f].ok).map((f) => runs[f].error))];
const prog = (f) => (runs[f].ok ? runs[f].program : null);
for (const f of FAMILIES) {
  const p = prog(f);
  if (p && !p[f] || (p && f === "rectangular" && !p[f]?.length)) warnings.add(`No ${f} layout: add lock.${f}(…), or that size shows "No ${f} layout".`);
}

if (args.includes("--json")) {
  console.log(JSON.stringify({ errors, warnings: [...warnings], rectangular: prog("rectangular")?.rectangular, circular: prog("circular")?.circular, inline: prog("inline")?.inline, refreshAfter: prog("rectangular")?.refreshAfter }, (k, v) => (k === "ops" ? `[${v.length} canvas ops]` : v), 2));
  process.exit(errors.length ? 1 : 0);
}

const html = (f, render) => (runs[f].ok ? render(prog(f)[f]) : `<div class="err">⚠︎</div>`);
const rect = html("rectangular", rectangularHTML), circ = html("circular", circularHTML), inl = html("inline", inlineHTML);
const time = now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }).replace(/\s?[AP]M/i, "");
const page = `<!doctype html><meta charset="utf-8"><title>${esc(path.basename(file))} · Lock Screen preview</title>
<style>
  body { margin: 0; padding: 24px; background: #111; color: #ddd; font: 14px -apple-system, system-ui, "Segoe UI", Roboto, sans-serif; }
  h1 { font-size: 15px; font-weight: 600; margin: 0 0 16px; }
  .row { display: flex; gap: 32px; flex-wrap: wrap; align-items: flex-start; }
  .phone { width: 364px; padding: 22px 0 26px; border-radius: 30px; background: linear-gradient(#5b5b66, #121216); color: #fff; display: flex; flex-direction: column; align-items: center; gap: 6px; filter: grayscale(1); }
  .clock { font: 700 76px/1 -apple-system, system-ui, sans-serif; letter-spacing: -2px; }
  .widgets { display: flex; gap: 12px; margin-top: 8px; }
  .slot { outline: 1px dashed #ffffff33; }
  .slot.c { border-radius: 50%; }
  .zoom { transform: scale(3); transform-origin: top left; }
  .zoomwrap { display: flex; flex-direction: column; gap: 4px; }
  .zoombox { position: relative; overflow: visible; }
  .lbl { font-size: 12px; color: #999; margin-bottom: 4px; }
  .circ { width: 76px; height: 76px; border-radius: 50%; position: relative; display: flex; align-items: center; justify-content: center; overflow: hidden; color: #fff; }
  .circ.bg { background: #ffffff29; }
  .circ.col { flex-direction: column; }
  .ring { position: absolute; inset: 0; width: 76px; height: 76px; }
  .center { position: relative; display: flex; flex-direction: column; align-items: center; font: 600 14px ui-rounded, -apple-system, system-ui, sans-serif; }
  .gcap { font: 500 9px -apple-system, system-ui, sans-serif; opacity: 0.8; }
  .mm { position: absolute; bottom: 6px; width: 54px; display: flex; justify-content: space-between; font-size: 9px; }
  .num { font: 600 24px/1 ui-rounded, -apple-system, system-ui, sans-serif; max-width: 64px; overflow: hidden; white-space: nowrap; }
  .cap { font-size: 10px; font-weight: 500; max-width: 60px; overflow: hidden; white-space: nowrap; }
  .cd { font: 600 15px ui-rounded, -apple-system, system-ui, sans-serif; font-variant-numeric: tabular-nums; }
  .rect { width: 172px; height: 76px; overflow: hidden; display: flex; flex-direction: column; gap: 1px; color: #fff; }
  .title { font-weight: 600; font-size: 17px; line-height: 21px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; gap: 4px; align-items: center; }
  .line { font-size: 17px; line-height: 21px; display: flex; gap: 4px; align-items: center; white-space: nowrap; overflow: hidden; }
  .grow { flex: 1; overflow: hidden; text-overflow: ellipsis; }
  .mono { font-family: ui-monospace, Menlo, monospace; }
  .small { font-size: 12px; } .tiny { font-size: 10px; } .dim { opacity: 0.6; }
  .barrow { display: flex; flex-direction: column; gap: 2px; } .barline { display: flex; gap: 4px; align-items: center; }
  .bar { flex: 1; height: 6px; border-radius: 3px; background: #ffffff40; overflow: hidden; } .bar i { display: block; height: 100%; background: #fff; border-radius: 3px; }
  .pic { display: flex; align-items: center; width: 100%; } .pic svg, .pic canvas { display: block; }
  .inline { font-size: 15px; height: 22px; display: flex; gap: 4px; align-items: center; white-space: nowrap; max-width: 234px; overflow: hidden; text-overflow: ellipsis; }
  .sym { display: inline-flex; align-items: center; justify-content: center; border: 1px solid currentColor; border-radius: 3px; font-size: 7px; line-height: 1; text-transform: uppercase; opacity: 0.85; flex: none; }
  .err { color: #fff; font-size: 20px; display: flex; align-items: center; justify-content: center; width: 100%; height: 100%; }
  .notes { max-width: 760px; } .notes li { margin: 4px 0; } .bad { color: #ff6b6b; } .warn { color: #ffcc66; }
  code { background: #ffffff14; padding: 1px 4px; border-radius: 3px; }
</style>
<h1>${esc(path.basename(file))} — Lock Screen preview (approximate; one tint, real point sizes)</h1>
<div class="row">
  <div class="phone">
    <div class="slot" style="width:234px;height:22px;display:flex;justify-content:center">${inl}</div>
    <div class="clock">${esc(time)}</div>
    <div class="widgets"><div class="slot c">${circ}</div><div class="slot">${rect}</div></div>
  </div>
  <div class="zoomwrap" style="filter:grayscale(1)">
    <div class="lbl">rectangular ×3</div><div class="zoombox" style="height:228px;width:516px"><div class="zoom slot" style="width:172px">${rect.replace(/id="cv(\d+)"/g, 'id="z$1"')}</div></div>
  </div>
  <div class="zoomwrap" style="filter:grayscale(1)">
    <div class="lbl">circular ×3</div><div class="zoombox" style="height:228px;width:228px"><div class="zoom slot c" style="width:76px">${circ.replace(/id="cv(\d+)"/g, 'id="z$1"')}</div></div>
  </div>
</div>
<div class="notes">
  ${errors.length ? `<h3 class="bad">Script errors</h3><ul>${errors.map((e) => `<li class="bad">${esc(e)}</li>`).join("")}</ul>` : ""}
  ${warnings.size ? `<h3 class="warn">Warnings</h3><ul>${[...warnings].map((w) => `<li class="warn">${esc(w)}</li>`).join("")}</ul>` : ""}
  ${symbolsUsed.size ? `<h3>SF Symbols (drawn here as labelled boxes)</h3><p>${[...symbolsUsed].map((s) => `<code>${esc(s)}</code>`).join(" ")} — check each name exists in Apple's SF Symbols catalogue; an unknown name draws nothing on the phone.</p>` : ""}
  <p>Refresh: every ${prog("rectangular")?.refreshAfter ?? 30} min (iOS may stretch this).</p>
</div>
<ul id="clipped" class="notes"></ul>
<script>
// Real text measurement: anything cut off in the actual-size phone mock-up.
const clipped = [...document.querySelectorAll(".phone .title, .phone .grow, .phone .inline, .phone .num, .phone .cap")]
  .filter((el) => el.scrollWidth > el.clientWidth + 1).map((el) => el.textContent.trim());
document.getElementById("clipped").innerHTML = clipped.map((t) => '<li class="warn">"' + t.replace(/[<&]/g, "") + '" is cut off; shorten it.</li>').join("");
window.__clipped = clipped;
const canvases = ${JSON.stringify(canvases)};
for (const c of canvases) for (const prefix of ["cv", "z"]) {
  const el = document.getElementById(prefix + c.id.slice(2)); if (!el) continue;
  const ctx = el.getContext("2d"); ctx.scale(3, 3); const grads = {};
  for (const op of c.ops) {
    if (op[0] === "set") ctx[op[1]] = op[2] && op[2].gradient !== undefined ? grads[op[2].gradient] : op[2];
    else if (op[0] === "gradient") grads[op[1]] = ctx.createLinearGradient(...op[2]);
    else if (op[0] === "stop") grads[op[1]].addColorStop(op[2], op[3]);
    else if (typeof ctx[op[1]] === "function") ctx[op[1]](...op[2]);
  }
}
</script>`;

const out = flag("--out") || flag("-o") || file.replace(/\.gitsidian\.lock$/i, "") + ".lock-preview.html";
fs.writeFileSync(out, page);
console.log(`Preview: ${out}`);
if (errors.length) console.log("Script errors:\n  " + errors.join("\n  "));
if (warnings.size) console.log("Warnings:\n  " + [...warnings].join("\n  "));

const png = flag("--png");
if (png) {
  let playwright;
  try { playwright = createRequire(import.meta.url)("playwright"); } catch {
    try { playwright = createRequire(path.join(process.cwd(), "x.js"))("playwright"); } catch {}
  }
  if (!playwright) {
    console.log(`Playwright isn't installed, so no PNG. Open ${out} in a browser, or: npx playwright screenshot --full-page file://${path.resolve(out)} ${png}`);
  } else {
    const browser = await playwright.chromium.launch();
    const pageObj = await browser.newPage({ viewport: { width: 1180, height: 520 }, deviceScaleFactor: 2 });
    await pageObj.goto("file://" + path.resolve(out));
    const clipped = await pageObj.evaluate(() => window.__clipped || []);
    for (const t of clipped) console.log(`Cut off: "${t}" doesn't fit; shorten it.`);
    await pageObj.screenshot({ path: png, fullPage: true });
    await browser.close();
    console.log(`Screenshot: ${png}`);
  }
}
process.exit(errors.length ? 1 : 0);
