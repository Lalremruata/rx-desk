// Builds docs/user-guide/*.md (+ images/) into docs/user-guide/RxDesk-User-Guide.pdf.
//
//   flutter test tool/user_guide/screenshots_test.dart   # refresh the screenshots
//   node tool/user_guide/build_pdf.mjs                   # then build the PDF
//
// No npm packages: a small Markdown converter for what the guide uses
// (headings, paragraphs, lists, tables, quotes, images, links, bold/italic/code)
// and Chrome's own print-to-PDF over the DevTools protocol (Node 22 WebSocket).
// Set CHROME=/path/to/chrome if Chrome isn't in the usual place.
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const guide = join(root, 'docs/user-guide');
const outPdf = join(guide, 'RxDesk-User-Guide.pdf');
const buildDir = join(root, 'build/user_guide');

// ---------------------------------------------------------------------------
// Markdown → HTML

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const slug = (text) =>
  text
    .replace(/<[^>]+>/g, '')
    .replace(/[*`_]/g, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .trim()
    .replace(/\s/g, '-');

const anchors = new Set();
const links = [];

function linkTarget(href, chapter) {
  if (/^[a-z]+:/i.test(href)) return href;
  const [file, hash] = href.split('#');
  const ch = file ? file.replace(/\.md$/, '') : chapter;
  const id = hash ? `${ch}--${hash}` : ch;
  links.push({ from: chapter, id });
  return `#${id}`;
}

function inline(text, chapter) {
  const codes = [];
  let s = text.replace(/`([^`]+)`/g, (_, c) => {
    codes.push(`<code>${esc(c)}</code>`);
    return `\u0000${codes.length - 1}\u0000`;
  });
  s = esc(s);
  s = s.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (_, alt, src) => `<img src="${pathToFileURL(join(guide, src)).href}" alt="${alt}">`);
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, t, href) => `<a href="${linkTarget(href, chapter)}">${t}</a>`);
  s = s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^\p{L}\p{N}*])\*(?!\s)([^*]+?)\*(?![\p{L}\p{N}])/gu, '$1<em>$2</em>');
  s = s.replace(/ ← Contents/g, '');
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[Number(i)]);
}

const indentOf = (l) => l.match(/^\s*/)[0].length;
const listRe = /^(\s*)([-*]|\d+\.)\s+(.*)$/;

function renderBlocks(lines, chapter) {
  const out = [];
  let para = [];
  const flush = () => {
    if (para.length) out.push(`<p>${inline(para.join(' '), chapter)}</p>`);
    para = [];
  };
  for (let i = 0; i < lines.length; ) {
    const line = lines[i];
    if (!line.trim()) {
      flush();
      i++;
      continue;
    }
    let m;
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) {
      flush();
      const level = m[1].length;
      const id = level === 1 ? chapter : `${chapter}--${slug(m[2])}`;
      anchors.add(id);
      out.push(`<h${level} id="${id}">${inline(m[2], chapter)}</h${level}>`);
      i++;
    } else if (/^\s*---+\s*$/.test(line)) {
      flush();
      out.push('<hr>');
      i++;
    } else if ((m = line.match(/^!\[([^\]]*)\]\(([^)]+)\)\s*$/))) {
      flush();
      const src = join(guide, m[2]);
      if (!existsSync(src)) console.warn(`! missing image ${m[2]} (${chapter})`);
      out.push(`<figure><img src="${pathToFileURL(src).href}" alt="${esc(m[1])}"><figcaption>${inline(m[1], chapter)}</figcaption></figure>`);
      i++;
    } else if (line.startsWith('|')) {
      flush();
      const rows = [];
      while (i < lines.length && lines[i].startsWith('|')) rows.push(lines[i++]);
      const cells = (r) => r.trim().replace(/^\||\|$/g, '').split(/(?<!\\)\|/).map((c) => c.trim());
      const align = cells(rows[1]).map((c) => (c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : ''));
      const td = (tag, c, j) => `<${tag}${align[j] ? ` style="text-align:${align[j]}"` : ''}>${inline(c, chapter)}</${tag}>`;
      out.push(
        `<table><thead><tr>${cells(rows[0]).map((c, j) => td('th', c, j)).join('')}</tr></thead><tbody>` +
          rows.slice(2).map((r) => `<tr>${cells(r).map((c, j) => td('td', c, j)).join('')}</tr>`).join('') +
          '</tbody></table>',
      );
    } else if (line.startsWith('>')) {
      flush();
      const q = [];
      while (i < lines.length && lines[i].startsWith('>')) q.push(lines[i++].replace(/^>\s?/, ''));
      out.push(`<blockquote>${renderBlocks(q, chapter)}</blockquote>`);
    } else if ((m = line.match(listRe))) {
      flush();
      const r = renderList(lines, i, chapter);
      out.push(r.html);
      i = r.next;
    } else {
      para.push(line.trim());
      i++;
    }
  }
  flush();
  return out.join('\n');
}

function renderList(lines, start, chapter) {
  const base = indentOf(lines[start]);
  const ordered = /\d/.test(lines[start].match(listRe)[2]);
  const first = ordered ? parseInt(lines[start].match(listRe)[2], 10) : 1;
  const items = [];
  let i = start;
  while (i < lines.length) {
    const m = lines[i].match(listRe);
    if (!m || m[1].length !== base || /\d/.test(m[2]) !== ordered) break;
    const contentIndent = m[1].length + m[2].length + 1;
    const body = [m[3]];
    i++;
    while (i < lines.length) {
      const l = lines[i];
      if (!l.trim()) {
        // A blank line continues the item only if more indented content follows.
        let j = i;
        while (j < lines.length && !lines[j].trim()) j++;
        if (j < lines.length && indentOf(lines[j]) > base) {
          body.push('');
          i++;
          continue;
        }
        break;
      }
      if (indentOf(l) <= base) break;
      body.push(l.slice(Math.min(contentIndent, indentOf(l))));
      i++;
    }
    let html = renderBlocks(body, chapter);
    const single = html.match(/^<p>([\s\S]*?)<\/p>(\n?[\s\S]*)$/);
    if (single && !single[1].includes('<p>')) html = single[1] + single[2];
    items.push(`<li>${html}</li>`);
    // Blank lines between items of the same list.
    let j = i;
    while (j < lines.length && !lines[j].trim()) j++;
    const next = j < lines.length && lines[j].match(listRe);
    if (next && next[1].length === base && /\d/.test(next[2]) === ordered) i = j;
    else break;
  }
  const tag = ordered ? 'ol' : 'ul';
  return { html: `<${tag}${ordered && first !== 1 ? ` start="${first}"` : ''}>${items.join('')}</${tag}>`, next: i };
}

// ---------------------------------------------------------------------------
// The document

const chapters = ['README', ...readdirSync(guide).filter((f) => /^\d\d-.*\.md$/.test(f)).sort().map((f) => f.replace(/\.md$/, ''))];
const body = chapters
  .map((ch) => {
    let md = readFileSync(join(guide, `${ch}.md`), 'utf8');
    md = md.replace(/^\[← Contents\]\(README\.md\)\s*$/m, '');
    if (ch === 'README') md = md.replace(/^# RxDesk user guide\s*$/m, '# About this guide');
    return `<section class="chapter" id="sec-${ch}">${renderBlocks(md.split('\n'), ch)}</section>`;
  })
  .join('\n');

const broken = links.filter((l) => !anchors.has(l.id));
for (const b of broken) console.warn(`! broken link in ${b.from}: #${b.id}`);

const font = (file) => `data:font/ttf;base64,${readFileSync(join(root, 'assets/fonts', file)).toString('base64')}`;
const icon = pathToFileURL(join(root, 'assets/icon/app_icon.png')).href;
const month = new Date().toLocaleDateString('en-IN', { month: 'long', year: 'numeric' });
const version = (readFileSync(join(root, 'pubspec.yaml'), 'utf8').match(/^version:\s*([^\s+]+)/m) || [])[1] || '';

const html = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>RxDesk user guide</title>
<style>
@font-face { font-family: Inter; font-weight: 400; src: url(${font('Inter-Regular.ttf')}); }
@font-face { font-family: Inter; font-weight: 500; src: url(${font('Inter-Medium.ttf')}); }
@font-face { font-family: Inter; font-weight: 600; src: url(${font('Inter-SemiBold.ttf')}); }
@font-face { font-family: Inter; font-weight: 700; src: url(${font('Inter-Bold.ttf')}); }
@font-face { font-family: 'Space Grotesk'; font-weight: 500; src: url(${font('SpaceGrotesk-Medium.ttf')}); }
@font-face { font-family: 'Space Grotesk'; font-weight: 600; src: url(${font('SpaceGrotesk-SemiBold.ttf')}); }
@font-face { font-family: 'Space Grotesk'; font-weight: 700; src: url(${font('SpaceGrotesk-Bold.ttf')}); }
@page { size: A4; margin: 18mm 16mm 20mm; }
@page :first { margin: 0; }
:root { --accent: #0F766E; --soft: #E7F1F0; --ink: #0F172A; --body: #334155; --muted: #64748B; --line: #E2E8F0; }
html { font-family: Inter, sans-serif; font-size: 10pt; line-height: 1.55; color: var(--body); }
body { margin: 0; }
h1, h2, h3, h4 { font-family: 'Space Grotesk', Inter, sans-serif; color: var(--ink); line-height: 1.25; break-after: avoid; }
h1 { font-size: 24pt; margin: 0 0 6mm; padding-bottom: 3mm; border-bottom: 2px solid var(--accent); }
h2 { font-size: 15pt; margin: 8mm 0 2.5mm; }
h3 { font-size: 12pt; margin: 6mm 0 2mm; }
h4 { font-size: 10.5pt; margin: 5mm 0 1.5mm; }
p { margin: 0 0 2.6mm; }
strong { color: var(--ink); font-weight: 600; }
a { color: var(--accent); text-decoration: none; }
code { font-family: Menlo, Consolas, monospace; font-size: 8.6pt; background: #F1F5F9; border: 1px solid var(--line); border-radius: 4px; padding: 0 3px; color: var(--ink); }
ul, ol { margin: 0 0 3mm; padding-left: 6mm; }
li { margin: 0 0 1.2mm; }
li > ul, li > ol { margin: 1.2mm 0 0; }
hr { border: 0; border-top: 1px solid var(--line); margin: 6mm 0; }
blockquote { margin: 0 0 3mm; padding: 2.5mm 4mm; background: var(--soft); border-left: 3px solid var(--accent); border-radius: 0 6px 6px 0; }
blockquote p:last-child { margin: 0; }
table { width: 100%; border-collapse: collapse; margin: 1mm 0 4mm; font-size: 9pt; break-inside: auto; }
tr { break-inside: avoid; }
th { text-align: left; font-weight: 600; color: var(--ink); background: #F8FAFC; }
th, td { border-bottom: 1px solid var(--line); padding: 1.6mm 2.2mm; vertical-align: top; }
figure { margin: 3mm 0 5mm; break-inside: avoid; }
figure img { display: block; width: 100%; border: 1px solid var(--line); border-radius: 6px; box-shadow: 0 1px 3px rgba(15,23,42,.08); }
figcaption { font-size: 8.5pt; color: var(--muted); margin-top: 1.5mm; text-align: center; }
.chapter { break-before: page; }
.cover { height: 297mm; box-sizing: border-box; padding: 0 22mm; display: flex; flex-direction: column; justify-content: center;
  background: linear-gradient(160deg, #F0F7F6 0%, #FFFFFF 55%); break-after: page; }
.cover img { width: 30mm; height: 30mm; border-radius: 7mm; margin-bottom: 10mm; }
.cover .title { font-family: 'Space Grotesk'; font-weight: 700; font-size: 40pt; color: var(--ink); line-height: 1.1; }
.cover .sub { font-size: 14pt; color: var(--body); margin-top: 4mm; max-width: 140mm; }
.cover .meta { margin-top: 18mm; font-size: 10pt; color: var(--muted); }
.cover .bar { width: 24mm; height: 2mm; background: var(--accent); border-radius: 1mm; margin: 10mm 0 0; }
</style></head><body>
<div class="cover">
  <img src="${icon}" alt="">
  <div class="title">RxDesk<br>User guide</div>
  <div class="sub">Billing, batch-wise stock, purchases, customer credit, reports and backups — for the Owner and the counter staff.</div>
  <div class="bar"></div>
  <div class="meta">${version ? `Version ${version} · ` : ''}${month}<br>Works fully offline · Windows and Android tablet</div>
</div>
${body}
</body></html>`;

mkdirSync(buildDir, { recursive: true });
const htmlPath = join(buildDir, 'guide.html');
writeFileSync(htmlPath, html);

// ---------------------------------------------------------------------------
// Print with Chrome (DevTools protocol)

const chrome =
  process.env.CHROME ||
  [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
  ].find(existsSync);
if (!chrome) throw new Error('Chrome not found — set CHROME=/path/to/chrome');

const profile = mkdtempSync(join(tmpdir(), 'rxdesk-guide-'));
const proc = spawn(chrome, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--allow-file-access-from-files', 'about:blank'], {
  stdio: ['ignore', 'ignore', 'pipe'],
});
const wsUrl = await new Promise((ok, fail) => {
  let buf = '';
  proc.stderr.on('data', (d) => {
    buf += d;
    const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
    if (m) ok(m[1]);
  });
  proc.on('exit', () => fail(new Error(`Chrome exited:\n${buf}`)));
});

const ws = new WebSocket(wsUrl);
await new Promise((ok) => ws.addEventListener('open', ok, { once: true }));
let seq = 0;
const pending = new Map();
const waiters = [];
ws.addEventListener('message', (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) {
    const { ok, fail } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? fail(new Error(JSON.stringify(msg.error))) : ok(msg.result);
  } else if (msg.method) {
    for (const w of [...waiters]) if (w.method === msg.method) { waiters.splice(waiters.indexOf(w), 1); w.ok(msg.params); }
  }
});
const send = (method, params = {}, sessionId) =>
  new Promise((ok, fail) => {
    const id = ++seq;
    pending.set(id, { ok, fail });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
const once = (method) => new Promise((ok) => waiters.push({ method, ok }));

try {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Page.enable', {}, sessionId);
  const loaded = once('Page.loadEventFired');
  await send('Page.navigate', { url: pathToFileURL(htmlPath).href }, sessionId);
  await loaded;
  await send('Runtime.evaluate', { expression: 'document.fonts.ready.then(() => Promise.all([...document.images].map(i => i.decode().catch(() => null))))', awaitPromise: true }, sessionId);
  const footer = `<div style="width:100%; font: 7.5pt -apple-system, 'Segoe UI', Arial, sans-serif; color:#64748B; padding: 0 16mm; display:flex; justify-content:space-between;">
    <span>RxDesk user guide</span><span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>`;
  const { stream } = await send(
    'Page.printToPDF',
    {
      printBackground: true,
      preferCSSPageSize: true,
      displayHeaderFooter: true,
      headerTemplate: '<span></span>',
      footerTemplate: footer,
      generateDocumentOutline: true,
      transferMode: 'ReturnAsStream',
    },
    sessionId,
  );
  const parts = [];
  for (;;) {
    const r = await send('IO.read', { handle: stream, size: 1 << 20 }, sessionId);
    parts.push(Buffer.from(r.data, r.base64Encoded ? 'base64' : 'utf8'));
    if (r.eof) break;
  }
  await send('IO.close', { handle: stream }, sessionId);
  writeFileSync(outPdf, Buffer.concat(parts));
  console.log(`Wrote ${outPdf} (${(Buffer.concat(parts).length / 1048576).toFixed(1)} MB)${broken.length ? ` — ${broken.length} broken link(s)` : ''}`);
} finally {
  ws.close();
  const exited = new Promise((ok) => proc.once('exit', ok));
  proc.kill();
  await exited;
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
