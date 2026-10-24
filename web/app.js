'use strict';
(() => {
const B = window.__BORION__;
const invoke = (c, a) => B.invoke(c, a);
const dlg = { open: o => B.invoke('dialog:open', o), save: o => B.invoke('dialog:save', o) };
const $ = id => document.getElementById(id);

// ---------------------------------------------------------------------------
// formatação (pt-BR)
// ---------------------------------------------------------------------------
const U = { KiB: 1024, MiB: 1048576, GiB: 1073741824 };
const nf = n => Math.round(n).toLocaleString('pt-BR');
const dec = (v, d) => v.toFixed(d).replace('.', ',');
const pct = v => v > 0 && v < 0.05 ? '<0,1%' : dec(v, 1) + '%';
const fmtB = b => b >= U.GiB ? dec(b / U.GiB, 2) + ' GiB' : b >= U.MiB ? dec(b / U.MiB, 1) + ' MiB' : b >= U.KiB ? dec(b / U.KiB, 1) + ' KiB' : Math.round(b) + ' B';
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const baseName = p => p.split(/[\\/:]/).filter(Boolean).pop() || p;

const C = { dados: 'var(--c-dados)', idx: 'var(--c-idx)', blob: 'var(--c-blob)', other: '#a7acb4', rest: '#d6dade' };
const CAT = { blob: 'blob', data: 'dados', index: 'idx' };
const DESC = {
  blob: 'Páginas com conteúdo de colunas BLOB que não cabem na página de dados do registro.',
  data: 'Páginas de dados (data pages) com os registros das tabelas.',
  index: 'Páginas das árvores B dos índices.',
  pointer: 'Ponteiros que mapeiam as páginas de dados de cada tabela.',
  index_root: 'Página raiz de índices de cada tabela.',
  pip: 'Inventário de páginas: marca quais páginas estão livres ou em uso.',
  free: 'Páginas existentes no arquivo mas ainda não alocadas.',
  header: 'Cabeçalho do banco de dados.',
  scn: 'Inventário de números de mudança de página (SCN).',
  generator: 'Valores atuais de generators / sequences.',
  tip: 'Estado das transações (ativa, confirmada, revertida, em limbo).'
};
const TABS = [
  { id: 'comp', label: 'Composição do arquivo' },
  { id: 'tab', label: 'Maiores tabelas' },
  { id: 'idx', label: 'Maiores índices' },
  { id: 'blob', label: 'Colunas BLOB por volume' },
  { id: 'obs', label: 'Observações' }
];

// ---------------------------------------------------------------------------
// estado
// ---------------------------------------------------------------------------
const S = {
  phase: 'empty',            // empty | running | error | ready
  report: null, D: null, error: '', progress: null,
  tab: 'tab',
  sort: { comp: { k: 'pages', d: -1 }, tab: { k: 'total', d: -1 }, idx: { k: 'size', d: -1 }, blob: { k: 'payload', d: -1 } },
  sel: { comp: null, tab: null, idx: null, blob: null }
};

// ---------------------------------------------------------------------------
// modelo derivado do relatório
// ---------------------------------------------------------------------------
function derive(r) {
  const ps = r.pageSize;
  const census = r.census;
  const sumTables = r.tables.reduce((a, t) => a + t.totalBytes, 0);
  const FILE = r.fileSize ?? (census ? census.totalPages * ps : sumTables);
  const PAGES = census ? census.totalPages : Math.round(FILE / ps);
  const BLOBTOT = r.blobs.reduce((a, b) => a + b.bytes, 0);

  const comp = census ? census.rows.map(x => ({
    id: x.key, label: x.label, desc: DESC[x.key] || '', color: C[CAT[x.key] || 'other'],
    pages: x.pages, b: x.bytes, p: x.pct, pagesTxt: nf(x.pages), sizeTxt: fmtB(x.bytes), pctTxt: pct(x.pct),
    w: Math.max(x.pct, 0.5) + '%',
    s: { label: x.label, pages: x.pages, size: x.bytes, pct: x.pct },
    csv: [x.label, x.pages, x.bytes, x.pct.toFixed(2)]
  })) : [];

  const maxT = Math.max(1, ...r.tables.map(t => t.totalBytes));
  const tab = r.tables.map(t => ({
    id: t.name, name: t.name, db: t.dataBytes, ib: t.indexBytes, bb: t.blobBytes, tb: t.totalBytes,
    dados: fmtB(t.dataBytes), idx: fmtB(t.indexBytes), blobs: fmtB(t.blobBytes), total: fmtB(t.totalBytes),
    regs: t.records, regsTxt: nf(t.records), bpr: Math.round(t.avgRecord), fill: t.fill, fillTxt: t.fill + '%',
    fillC: t.fill > 0 && t.fill < 60 ? 'var(--warn)' : 'inherit', nidx: t.indexCount, vers: t.versions,
    dC: t.dataBytes ? 'inherit' : 'var(--faint)', iC: t.indexBytes ? 'inherit' : 'var(--faint)', bC: t.blobBytes ? 'inherit' : 'var(--faint)',
    dW: t.dataBytes / maxT * 100 + '%', iW: t.indexBytes / maxT * 100 + '%', bW: t.blobBytes / maxT * 100 + '%',
    s: { name: t.name, dados: t.dataBytes, idx: t.indexBytes, blobs: t.blobBytes, total: t.totalBytes, regs: t.records, bpr: t.avgRecord, fill: t.fill, nidx: t.indexCount },
    csv: [t.name, t.dataBytes, t.indexBytes, t.blobBytes, t.totalBytes, t.records, Math.round(t.avgRecord), t.fill, t.indexCount, t.versions]
  }));

  const maxI = Math.max(1, ...r.indexes.map(i => i.bytes));
  const idx = r.indexes.map(i => ({
    id: i.table + '\u0000' + i.name, name: i.name, table: i.table, size: fmtB(i.bytes), b: i.bytes, nodes: i.nodes, nodesTxt: nf(i.nodes),
    dup: i.dupPct, dupTxt: Math.round(i.dupPct) + '%', depth: i.depth, w: i.bytes / maxI * 100 + '%',
    s: { name: i.name, table: i.table, size: i.bytes, nodes: i.nodes, dup: i.dupPct, depth: i.depth },
    csv: [i.name, i.table, i.bytes, i.nodes, Math.round(i.dupPct), i.depth]
  }));

  const maxB = Math.max(1, ...r.blobs.map(b => b.bytes));
  const blob = r.blobs.filter(b => b.bytes > 0).map(b => {
    const p = BLOBTOT ? b.bytes / BLOBTOT * 100 : 0;
    return {
      id: b.table + '.' + b.column, tbl: b.table, col: b.column, payload: fmtB(b.bytes), b: b.bytes, qtd: b.count, qtdTxt: nf(b.count),
      media: fmtB(b.avg), mb: b.avg, p, pctTxt: pct(p), w: Math.max(b.bytes / maxB * 100, 0.3) + '%',
      s: { name: b.table + '.' + b.column, payload: b.bytes, qtd: b.count, media: b.avg, pct: b.bytes },
      csv: [b.table + '.' + b.column, b.bytes, b.count, Math.round(b.avg), p.toFixed(2)]
    };
  });

  return { comp, tab, idx, blob, FILE, PAGES, BLOBTOT, census, sumTables };
}

function sorted(t) {
  const s = S.sort[t];
  return [...S.D[t]].sort((a, b) => {
    const x = a.s[s.k], y = b.s[s.k];
    return (typeof x === 'string' ? x.localeCompare(y) : x - y) * s.d;
  });
}

function selected(t) {
  const list = S.D[t];
  return list.find(x => x.id === S.sel[t]) || sorted(t)[0] || null;
}

// ---------------------------------------------------------------------------
// painel de detalhe
// ---------------------------------------------------------------------------
function detail(t) {
  const D = S.D, id = selected(t)?.id;
  if (id === undefined) return null;
  const seg = (label, b, tot, color) => ({ label, value: fmtB(b), pct: pct(tot ? b / tot * 100 : 0), w: (tot ? b / tot * 100 : 0) + '%', color });
  if (t === 'comp') {
    const r = D.comp.find(x => x.id === id);
    return { kind: 'Tipo de página', title: r.label, sub: r.pagesTxt + ' páginas', big: r.sizeTxt, bigLabel: r.pctTxt + ' do arquivo', desc: r.desc,
      segs: [seg(r.label, r.b, D.FILE, r.color), seg('Restante do arquivo', D.FILE - r.b, D.FILE, C.rest)],
      kv: [['Páginas', r.pagesTxt], ['Bytes', nf(r.b)], ['Tamanho', r.sizeTxt], ['% do arquivo', r.pctTxt]], groups: [] };
  }
  if (t === 'tab') {
    const r = D.tab.find(x => x.id === id);
    const ix = D.idx.filter(x => x.table === r.name), bl = D.blob.filter(x => x.tbl === r.name), groups = [];
    if (ix.length) { const m = Math.max(...ix.map(x => x.b)) || 1; groups.push({ title: 'Índices da tabela', items: ix.slice().sort((a, b) => b.b - a.b).slice(0, 15).map(x => ({ name: x.name, value: x.size, w: x.b / m * 100 + '%', color: C.idx })) }); }
    if (bl.length) { const m = Math.max(...bl.map(x => x.b)) || 1; groups.push({ title: 'Colunas BLOB', items: bl.map(x => ({ name: x.col, value: x.payload, w: Math.max(x.b / m * 100, 1) + '%', color: C.blob })) }); }
    return { kind: 'Tabela', title: r.name, sub: r.regsTxt + ' registros', big: r.total, bigLabel: pct(D.FILE ? r.tb / D.FILE * 100 : 0) + ' do arquivo', desc: '',
      segs: [seg('Dados', r.db, r.tb, C.dados), seg('Índices', r.ib, r.tb, C.idx), seg('Blobs', r.bb, r.tb, C.blob)],
      kv: [['Registros', r.regsTxt], ['Bytes por registro', String(r.bpr)], ['Fill médio das páginas', r.fillTxt], ['Índices', String(r.nidx)], ['Versões de registro', nf(r.vers)]], groups };
  }
  if (t === 'idx') {
    const r = D.idx.find(x => x.id === id), tr = D.tab.find(x => x.name === r.table);
    const tot = tr && tr.ib ? tr.ib : r.b, others = D.idx.filter(x => x.table === r.table && x.id !== r.id);
    const groups = others.length ? [{ title: 'Outros índices da tabela', items: others.slice().sort((a, b) => b.b - a.b).slice(0, 15).map(x => ({ name: x.name, value: x.size, w: (r.b ? Math.min(x.b / r.b * 100, 100) : 0) + '%', color: C.idx })) }] : [];
    return { kind: 'Índice', title: r.name, sub: 'Tabela ' + r.table, big: r.size, bigLabel: pct(tot ? r.b / tot * 100 : 0) + ' dos índices da tabela', desc: '',
      segs: [seg('Este índice', r.b, tot, C.idx), seg('Demais índices da tabela', Math.max(tot - r.b, 0), tot, C.rest)],
      kv: [['Nodes', r.nodesTxt], ['Duplicatas', r.dupTxt], ['Profundidade', String(r.depth)], ['Bytes por node', r.nodes ? dec(r.b / r.nodes, 1) : '—']], groups };
  }
  const r = D.blob.find(x => x.id === id), tr = D.tab.find(x => x.name === r.tbl);
  const groups = tr && tr.tb ? [{ title: 'Tabela ' + tr.name, items: [
    { name: 'Dados', value: tr.dados, w: tr.db / tr.tb * 100 + '%', color: C.dados },
    { name: 'Índices', value: tr.idx, w: tr.ib / tr.tb * 100 + '%', color: C.idx },
    { name: 'Blobs', value: tr.blobs, w: tr.bb / tr.tb * 100 + '%', color: C.blob }] }] : [];
  return { kind: 'Coluna BLOB', title: r.col, sub: 'Tabela ' + r.tbl, big: r.payload, bigLabel: r.pctTxt + ' do payload BLOB', desc: '',
    segs: [seg('Esta coluna', r.b, D.BLOBTOT, C.blob), seg('Demais colunas', D.BLOBTOT - r.b, D.BLOBTOT, C.rest)],
    kv: [['Quantidade de blobs', r.qtdTxt], ['Tamanho médio', r.media], ['Payload', r.payload]], groups };
}

// ---------------------------------------------------------------------------
// renderização
// ---------------------------------------------------------------------------
function th(t, key, label, cls, extra = '') {
  const s = S.sort[t], on = s.k === key, arrow = on ? (s.d < 0 ? '↓' : '↑') : '';
  const right = cls.includes('r');
  return `<div class="c th sortable ${cls} ${on ? 'on' : ''}" data-sort="${t}:${key}" ${extra}>${right ? (arrow ? arrow + ' ' : '') + label : label + (arrow ? ' ' + arrow : '')}</div>`;
}
const thp = (label, cls = '') => `<div class="c th ${cls}">${label}</div>`;
const rowAttrs = (t, r) => `class="g r ${S.sel[t] === r.id || (!S.sel[t] && r === selectedRow[t]) ? 'sel' : ''}" data-sel="${t}" data-id="${esc(r.id)}"`;
let selectedRow = {};

function gridComp() {
  const cols = 'minmax(220px,1.4fr) minmax(160px,2fr) 120px 110px 80px';
  const rows = sorted('comp'), tp = rows.reduce((a, r) => a + r.pages, 0), tb = rows.reduce((a, r) => a + r.b, 0);
  return `<div class="g h" style="--cols:${cols}">${th('comp', 'label', 'Tipo de página', 'first')}${thp('Distribuição')}${th('comp', 'pages', 'Páginas', 'r')}${th('comp', 'size', 'Tamanho', 'r')}${th('comp', 'pct', '%', 'r last')}</div>` +
    rows.map(r => `<div ${rowAttrs('comp', r)} style="--cols:${cols};height:38px"><div class="ind"></div>
      <div class="c first nm"><div class="sw" style="background:${r.color}"></div><span class="ell">${esc(r.label)}</span></div>
      <div class="c"><div class="bar"><div style="width:${r.w};background:${r.color};border-radius:4px"></div></div></div>
      <div class="c r">${r.pagesTxt}</div><div class="c r">${r.sizeTxt}</div><div class="c r last muted">${r.pctTxt}</div></div>`).join('') +
    `<div class="g tot" style="--cols:${cols}"><div class="c" style="padding-left:36px">Total</div><div></div><div class="c r">${nf(tp)}</div><div class="c r">${fmtB(tb)}</div><div class="c r last">100%</div></div>`;
}

function gridTab() {
  const cols = 'minmax(210px,1.6fr) minmax(110px,1.2fr) 82px 82px 82px 82px 96px 64px 52px 48px';
  return `<div class="g h" style="--cols:${cols}">${th('tab', 'name', 'Tabela', 'first')}${thp('Composição')}${th('tab', 'dados', 'Dados', 'r')}${th('tab', 'idx', 'Índices', 'r')}${th('tab', 'blobs', 'Blobs', 'r')}${th('tab', 'total', 'Total', 'r')}${th('tab', 'regs', 'Registros', 'r')}${th('tab', 'bpr', 'B/reg', 'r')}${th('tab', 'fill', 'Fill', 'r')}${th('tab', 'nidx', '#Idx', 'r', 'style="padding:0 14px 0 6px"')}</div>` +
    sorted('tab').map(r => `<div ${rowAttrs('tab', r)} style="--cols:${cols};height:36px"><div class="ind"></div>
      <div class="c first mono ell">${esc(r.name)}</div>
      <div class="c"><div class="bar"><div style="width:${r.dW};background:var(--c-dados)"></div><div style="width:${r.iW};background:var(--c-idx)"></div><div style="width:${r.bW};background:var(--c-blob)"></div></div></div>
      <div class="c r" style="color:${r.dC}">${r.dados}</div><div class="c r" style="color:${r.iC}">${r.idx}</div><div class="c r" style="color:${r.bC}">${r.blobs}</div>
      <div class="c r" style="font-weight:600">${r.total}</div><div class="c r">${r.regsTxt}</div><div class="c r">${r.bpr}</div>
      <div class="c r" style="color:${r.fillC}">${r.fillTxt}</div><div class="c r" style="padding:0 14px 0 6px">${r.nidx}</div></div>`).join('');
}

function gridIdx() {
  const cols = 'minmax(230px,1.5fr) minmax(190px,1.2fr) minmax(120px,1.2fr) 96px 110px 64px 70px';
  return `<div class="g h" style="--cols:${cols}">${th('idx', 'name', 'Índice', 'first')}${th('idx', 'table', 'Tabela', '', 'style="padding:0 10px"')}${thp('Tamanho relativo')}${th('idx', 'size', 'Tamanho', 'r')}${th('idx', 'nodes', 'Nodes', 'r')}${th('idx', 'dup', 'Dup', 'r')}${th('idx', 'depth', 'Depth', 'r last')}</div>` +
    sorted('idx').map(r => `<div ${rowAttrs('idx', r)} style="--cols:${cols};height:36px"><div class="ind"></div>
      <div class="c first mono ell">${esc(r.name)}</div><div class="c mono ell muted" style="padding:0 10px">${esc(r.table)}</div>
      <div class="c"><div class="bar"><div style="width:${r.w};background:var(--c-idx);border-radius:4px"></div></div></div>
      <div class="c r" style="font-weight:600">${r.size}</div><div class="c r">${r.nodesTxt}</div><div class="c r muted">${r.dupTxt}</div><div class="c r last">${r.depth}</div></div>`).join('');
}

function gridBlob() {
  const cols = 'minmax(280px,1.7fr) minmax(140px,1.6fr) 100px 100px 90px 92px';
  return `<div class="g h" style="--cols:${cols}">${th('blob', 'name', 'Coluna', 'first')}${thp('Volume')}${th('blob', 'payload', 'Payload', 'r')}${th('blob', 'qtd', 'Qtd', 'r')}${th('blob', 'media', 'Média', 'r')}${th('blob', 'pct', '% blobs', 'r last')}</div>` +
    sorted('blob').map(r => `<div ${rowAttrs('blob', r)} style="--cols:${cols};height:36px"><div class="ind"></div>
      <div class="c first mono ell"><span class="muted">${esc(r.tbl)}.</span><span>${esc(r.col)}</span></div>
      <div class="c"><div class="bar"><div style="width:${r.w};background:var(--c-blob);border-radius:4px"></div></div></div>
      <div class="c r" style="font-weight:600">${r.payload}</div><div class="c r">${r.qtdTxt}</div><div class="c r">${r.media}</div><div class="c r last muted">${r.pctTxt}</div></div>`).join('');
}

function legend3() {
  return `<div class="lg"><div><span class="sw" style="background:var(--c-dados)"></span>Dados</div><div><span class="sw" style="background:var(--c-idx)"></span>Índices</div><div><span class="sw" style="background:var(--c-blob)"></span>Blobs</div></div>`;
}

function hero() {
  const D = S.D, r = S.report;
  const sizeLbl = r.fileSize != null ? 'Tamanho do arquivo' : 'Tamanho estimado (tabelas + índices + blobs)';
  let segs = '', leg = '';
  if (D.census) {
    const by = k => D.census.rows.find(x => x.key === k)?.bytes || 0;
    const blobB = by('blob'), dadosB = by('data'), idxB = by('index'), other = Math.max(D.FILE - blobB - dadosB - idxB, 0);
    const list = [['BLOB', blobB, C.blob], ['Dados', dadosB, C.dados], ['Índices', idxB, C.idx], ['Outros', other, C.other]];
    segs = list.map(([, b, c]) => `<div style="width:${Math.max(b / D.FILE * 100, 0.4)}%;background:${c}"></div>`).join('');
    leg = list.map(([l, b, c]) => `<div class="it"><div class="sw" style="background:${c}"></div><span>${l}</span><span class="muted tnum">${fmtB(b)} · ${pct(b / D.FILE * 100)}</span></div>`).join('');
  } else {
    leg = `<div class="it muted">Composição indisponível: o censo de páginas não foi executado${r.fileSize == null ? ' (arquivo não acessível localmente)' : ''}.</div>`;
  }
  const top = [...D.tab].sort((a, b) => b.tb - a.tb)[0];
  return `<div class="card hero">
    <div class="size"><span class="lbl">${sizeLbl}</span><span class="big">${fmtB(D.FILE)}</span><span class="lbl tnum">${nf(D.PAGES)} páginas de ${nf(r.pageSize)} bytes</span></div>
    <div class="mid"><div class="compbar">${segs}</div><div class="legend">${leg}</div></div>
    <div class="side">
      <div class="kpi"><span class="lbl">Payload BLOB</span><span class="v">${r.blobsMeasured ? fmtB(D.BLOBTOT) : '—'}</span><span class="lbl tnum">${r.blobsMeasured ? nf(r.blobs.reduce((a, b) => a + b.count, 0)) + ' blobs' : 'não medido'}</span></div>
      <div class="kpi"><span class="lbl">Maior tabela</span><span class="v">${top ? fmtB(top.tb) : '—'}</span><span class="lbl">${top ? esc(top.name) : ''}</span></div>
    </div></div>`;
}

function detailPanel(t) {
  const d = detail(t);
  if (!d) return `<div class="card detail"></div>`;
  return `<div class="card detail">
    <div class="dh"><span class="k">${d.kind}</span><span class="tt">${esc(d.title)}</span><span class="k">${esc(d.sub)}</span></div>
    <div class="db">
      <div><div class="bigv">${d.big}</div><div class="k muted" style="font-size:12px">${d.bigLabel}</div></div>
      <div style="display:flex;flex-direction:column;gap:10px">
        <div class="stack">${d.segs.map(s => `<div style="width:${s.w};background:${s.color}"></div>`).join('')}</div>
        ${d.segs.map(s => `<div class="srow"><div class="sw" style="background:${s.color}"></div><span class="l">${esc(s.label)}</span><span class="v">${s.value}</span><span class="p">${s.pct}</span></div>`).join('')}
      </div>
      <div class="kv">${d.kv.map(([k, v]) => `<div><span>${k}</span><span style="text-align:right">${esc(v)}</span></div>`).join('')}</div>
      ${d.desc ? `<p class="desc">${esc(d.desc)}</p>` : ''}
      ${d.groups.map(g => `<div class="grp"><span class="gt">${esc(g.title)}</span>${g.items.map(i => `<div class="gi"><div class="top"><span>${esc(i.name)}</span><span style="flex:none">${i.value}</span></div><div class="mini"><div style="width:${i.w};background:${i.color}"></div></div></div>`).join('')}</div>`).join('')}
    </div></div>`;
}

const HEADS = r => ({
  comp: { title: 'Composição do arquivo', sub: S.D.census ? `Censo exato · ${nf(S.D.PAGES)} páginas de ${nf(r.pageSize)} bytes` : '' },
  tab: { title: 'Tabelas por tamanho', sub: `${nf(r.tables.length)} tabelas · dados + índices + blobs` },
  idx: { title: 'Índices por tamanho', sub: `${nf(r.indexes.length)} índices b-tree` },
  blob: { title: 'Colunas BLOB por volume', sub: r.blobsMeasured ? `Payload total ${fmtB(S.D.BLOBTOT)} em ${nf(r.blobs.reduce((a, b) => a + b.count, 0))} blobs` : 'Medição de BLOBs não executada' }
});

function mainReady() {
  const r = S.report, t = S.tab, heads = HEADS(r);
  selectedRow = { comp: sorted('comp')[0], tab: sorted('tab')[0], idx: sorted('idx')[0], blob: sorted('blob')[0] };
  let body;
  if (t === 'obs') {
    const dup = r.dup ? r.dup.pairs : null;
    body = `<div class="card panel"><div class="panel-head"><span class="t">Observações</span><span class="s">${r.findings.length} itens · análise em ${dec(r.elapsedMs / 1000, 1)} s</span></div>
      <div class="notes">${r.findings.length ? `<ul>${r.findings.map(f => `<li>${esc(f)}</li>`).join('')}</ul>` : '<p class="muted">Nenhum ponto de atenção encontrado.</p>'}
      ${dup && !dup.length ? '<p class="muted">Duplicação entre colunas BLOB: nada encontrado acima do limite.</p>' : ''}
      <h3>Cabeçalho da base</h3><div class="kv" style="max-width:520px">${r.header.map(([k, v]) => `<div><span>${esc(k)}</span><span>${esc(v)}</span></div>`).join('')}</div></div></div>`;
  } else if ((t === 'comp' && !S.D.census)) {
    body = `<div class="card panel"><div class="panel-head"><span class="t">${heads.comp.title}</span></div><div class="notes"><p class="muted">O censo de páginas não foi executado${r.fileSize == null ? ': o arquivo não está acessível neste computador' : ''}. Refaça a análise com “Censo de páginas” marcado.</p></div></div>`;
  } else if (t === 'blob' && !r.blobsMeasured) {
    body = `<div class="card panel"><div class="panel-head"><span class="t">${heads.blob.title}</span></div><div class="notes"><p class="muted">A medição de BLOBs não foi executada. Refaça a análise com “Medir payload das colunas BLOB” marcado.</p></div></div>`;
  } else {
    const grid = { comp: gridComp, tab: gridTab, idx: gridIdx, blob: gridBlob }[t]();
    body = `<div class="split"><div class="card panel"><div class="panel-head"><span class="t">${heads[t].title}</span><span class="s">${heads[t].sub}</span>${t === 'tab' ? legend3() : ''}</div><div class="scroller" id="scroller">${grid}</div></div>${detailPanel(t)}</div>`;
  }
  const seg = TABS.map(x => `<div data-tab="${x.id}" class="${x.id === t ? 'on' : ''}">${x.label}${x.id === 'obs' ? ` (${r.findings.length})` : ''}</div>`).join('');
  return hero() + `<div class="seg-wrap"><div class="seg">${seg}</div></div>` + (t === 'obs' ? `<div class="split">${body}</div>` : body);
}

function renderHead() {
  const r = S.report, running = S.phase === 'running';
  let name = 'Nenhuma base aberta', sub = 'Use “Analisar base…” para começar';
  if (r) {
    name = baseName(r.database);
    sub = `${fmtB(S.D.FILE)}${r.fileSize != null ? ` · ${nf(r.fileSize)} bytes` : ''} · ${S.D.census ? 'censo exato de páginas' : 'sem censo de páginas'}`;
  }
  $('head').innerHTML = `<div class="ttl"><div class="name">${esc(name)}</div><div class="sub">${esc(sub)}</div></div>
    ${running ? '<button class="btn" id="btn-abort">Cancelar análise</button>' : '<button class="btn" id="btn-open">Analisar base…</button>'}
    <button class="btn primary" id="btn-csv" ${S.phase === 'ready' && S.tab !== 'obs' ? '' : 'disabled'}><span>⤓</span><span>Exportar CSV</span></button>`;
}

function renderStatus() {
  const r = S.report;
  $('st-ps').textContent = r ? `Página de ${nf(r.pageSize)} bytes` : '';
  $('st-pages').textContent = r ? `${nf(S.D.PAGES)} páginas` : '';
  let right = '';
  if (S.phase === 'ready') {
    const t = S.tab, heads = HEADS(r);
    right = t === 'obs' ? 'Observações' : `${heads[t].title} · ${nf(S.D[t].length)} linhas`;
  } else if (S.phase === 'running' && S.progress) right = S.progress.msg;
  $('st-right').textContent = right;
  $('st-ready').textContent = S.phase === 'running' ? 'Analisando…' : 'Pronto';
}

function render() {
  const sc = $('scroller'), top = sc ? sc.scrollTop : 0, keepTab = sc && sc.dataset.tab === S.tab;
  const main = $('main');
  if (S.phase === 'ready') {
    main.innerHTML = mainReady();
    const n = $('scroller');
    if (n) { n.dataset.tab = S.tab; if (keepTab) n.scrollTop = top; }
  } else if (S.phase === 'running') {
    main.innerHTML = `<div class="empty"><div class="box"><h2>Analisando a base…</h2><p id="run-msg">${esc(S.progress?.msg || 'Iniciando…')}</p></div></div>`;
  } else if (S.phase === 'error') {
    main.innerHTML = `<div class="empty"><div class="box"><h2>Não foi possível analisar</h2><div class="err">${esc(S.error)}</div><button class="btn primary" id="btn-open2">Tentar novamente</button></div></div>`;
  } else {
    main.innerHTML = `<div class="empty"><div class="box"><h2>Estatísticas de tamanho Firebird</h2><p>Descubra onde o espaço da base está sendo usado: composição do arquivo por tipo de página, maiores tabelas e índices e volume por coluna BLOB. A leitura é somente leitura e usa a fbclient.dll diretamente.</p><button class="btn primary" id="btn-open2">Analisar base…</button></div></div>`;
  }
  renderHead();
  renderStatus();
}

// ---------------------------------------------------------------------------
// ações
// ---------------------------------------------------------------------------
function exportCsv() {
  const t = S.tab;
  if (S.phase !== 'ready' || t === 'obs') return;
  const H = {
    comp: ['tipo', 'paginas', 'bytes', 'percentual'],
    tab: ['tabela', 'dados_bytes', 'indices_bytes', 'blobs_bytes', 'total_bytes', 'registros', 'bytes_por_registro', 'fill_pct', 'indices', 'versoes'],
    idx: ['indice', 'tabela', 'bytes', 'nodes', 'dup_pct', 'depth'],
    blob: ['coluna', 'payload_bytes', 'quantidade', 'media_bytes', 'pct_blobs']
  };
  const file = { comp: 'composicao', tab: 'maiores_tabelas', idx: 'maiores_indices', blob: 'colunas_blob' }[t] + '.csv';
  const lines = [H[t].join(';')].concat(sorted(t).map(r => r.csv.map(v => typeof v === 'number' ? Math.round(v * 100) / 100 : v).join(';')));
  dlg.save({ defaultPath: file, filters: [{ name: 'CSV', extensions: ['csv'] }] }).then(path => {
    if (path) return invoke('save_text', { path, b64: btoa(unescape(encodeURIComponent(lines.join('\r\n')))) }).then(() => { $('st-right').textContent = 'CSV salvo em ' + path; });
  }).catch(e => { $('st-right').textContent = 'Falha ao salvar: ' + ((e && e.message) || e); });
}

function openDialog() {
  $('dlg-error').hidden = true;
  $('overlay').hidden = false;
  $('f-db').focus();
}
const closeDialog = () => { $('overlay').hidden = true; };

function saveSettings() {
  try {
    localStorage.setItem('fbstats.settings', JSON.stringify({
      db: $('f-db').value, user: $('f-user').value, client: $('f-client').value,
      census: $('f-census').checked, blobs: $('f-blobs').checked, dup: $('f-dup').checked
    }));
  } catch (_) {}
}
function loadSettings() {
  try {
    const s = JSON.parse(localStorage.getItem('fbstats.settings') || 'null');
    if (!s) return;
    $('f-db').value = s.db || ''; $('f-user').value = s.user || 'SYSDBA'; $('f-client').value = s.client || '';
    $('f-census').checked = s.census !== false; $('f-blobs').checked = s.blobs !== false; $('f-dup').checked = !!s.dup;
  } catch (_) {}
}

async function run() {
  const database = $('f-db').value.trim();
  if (!database) { const e = $('dlg-error'); e.textContent = 'Informe o caminho da base.'; e.hidden = false; return; }
  saveSettings();
  closeDialog();
  S.phase = 'running'; S.progress = { msg: 'Iniciando…' };
  setProgress(null);
  render();
  try {
    const report = await invoke('analyze', { params: {
      database, user: $('f-user').value.trim() || 'SYSDBA', password: $('f-pass').value,
      fbclient: $('f-client').value.trim() || null,
      census: $('f-census').checked, blobs: $('f-blobs').checked, dupScan: $('f-dup').checked
    } });
    S.report = report; S.D = derive(report);
    S.sel = { comp: null, tab: null, idx: null, blob: null };
    S.phase = 'ready';
    if (!S.D.census && S.tab === 'comp') S.tab = 'tab';
  } catch (e) {
    S.error = (e && e.message) || String(e);
    S.phase = S.error === 'cancelado' ? (S.report ? 'ready' : 'empty') : 'error';
  }
  setProgress(false);
  render();
}

function setProgress(pct) {
  const p = $('prog'), b = $('prog-bar');
  if (pct === false) { p.classList.remove('indet'); b.style.width = '0'; return; }
  if (pct == null) { p.classList.add('indet'); b.style.width = ''; return; }
  p.classList.remove('indet'); b.style.width = Math.min(pct, 100) + '%';
}

// ---------------------------------------------------------------------------
// eventos
// ---------------------------------------------------------------------------
document.addEventListener('click', ev => {
  const t = ev.target.closest('[data-sort],[data-sel],[data-tab],#btn-open,#btn-open2,#btn-abort,#btn-csv');
  if (!t) return;
  if (t.dataset.sort) {
    const [tab, k] = t.dataset.sort.split(':'), cur = S.sort[tab], str = ['name', 'label', 'table'].includes(k);
    S.sort[tab] = { k, d: cur.k === k ? -cur.d : (str ? 1 : -1) };
    render();
  } else if (t.dataset.sel) {
    S.sel[t.dataset.sel] = t.dataset.id; render();
  } else if (t.dataset.tab) {
    S.tab = t.dataset.tab; render();
  } else if (t.id === 'btn-open' || t.id === 'btn-open2') openDialog();
  else if (t.id === 'btn-abort') invoke('cancel_analysis');
  else if (t.id === 'btn-csv') exportCsv();
});

$('f-run').addEventListener('click', run);
$('f-cancel').addEventListener('click', closeDialog);
$('overlay').addEventListener('keydown', e => { if (e.key === 'Escape') closeDialog(); if (e.key === 'Enter' && e.target.tagName === 'INPUT' && e.target.type !== 'checkbox') run(); });
$('f-browse').addEventListener('click', async () => {
  const p = await dlg.open({ multiple: false, filters: [{ name: 'Bases Firebird', extensions: ['fdb', 'gdb', 'ello'] }, { name: 'Todos os arquivos', extensions: ['*'] }] });
  if (p) $('f-db').value = p;
});

const win = {
  minimize: () => B.invoke('window:minimize', { label: B.label }),
  toggleMaximize: () => B.invoke('window:toggleMaximize', { label: B.label }),
  close: () => B.invoke('window:close', { label: B.label })
};
$('btn-min').addEventListener('click', () => win.minimize());
$('btn-max').addEventListener('click', () => win.toggleMaximize());
$('btn-close').addEventListener('click', () => win.close());

B.listen('progress', p => {
  S.progress = p;
  if (S.phase !== 'running') return;
  setProgress(p.pct);
  const m = $('run-msg'); if (m) m.textContent = p.msg;
  $('st-right').textContent = p.msg;
});

loadSettings();
invoke('default_fbclient').then(p => { if (p && !$('f-client').value) $('f-client').placeholder = p; }).catch(() => {});
render();
invoke('startup_db').then(db => { if (db) { $('f-db').value = db; run(); } }).catch(() => {});
})();
