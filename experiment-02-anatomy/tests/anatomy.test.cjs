// 收藏 / 浏览历史 / 学习笔记的数据操作与边界情况测试。
// 1) 纯规则（model/AnatomyRules.ts）直接评测；
// 2) 存储层（store/AnatomyStore.ets）通过注入内存版 relationalStore 评测，
//    覆盖持久化、重复收藏、历史上限、笔记关联等行为。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

const candidates = [
  process.env.TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript',
  '/Applications/DevEco-Studio.app/Contents/plugins/openharmony/ace-server/node_modules/typescript'
].filter(Boolean);
const compilerPath = candidates.find(candidate => fs.existsSync(candidate));
if (!compilerPath) throw new Error('Set TYPESCRIPT_PATH to an existing TypeScript package directory.');
const ts = require(compilerPath);

function loadTypeScript(relativePath, imports) {
  const filename = path.resolve(__dirname, relativePath);
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true,
    fileName: filename.replace(/\.ets$/, '.ts')
  });
  assert.equal(result.diagnostics.length, 0);
  const loaded = new Module(filename, module);
  loaded.require = id => {
    assert.ok(Object.hasOwn(imports, id), 'Unexpected dependency: ' + id);
    return imports[id];
  };
  loaded._compile(result.outputText, filename);
  return loaded.exports;
}

// ---- 内存版 relationalStore，仅实现被使用到的接口 ----
const COLUMNS = {
  favorites: ['id', 'name', 'systemId', 'systemName', 'createdAt'],
  history: ['id', 'name', 'systemId', 'visitedAt'],
  notes: ['id', 'structureId', 'structureName', 'content', 'createdAt', 'updatedAt']
};
class ResultSet {
  constructor(rows, columns) { this.rows = rows; this.columns = columns; this.index = -1; }
  goToFirstRow() { if (this.rows.length === 0) return false; this.index = 0; return true; }
  goToNextRow() { this.index++; return this.index < this.rows.length; }
  getColumnIndex(name) {
    const i = this.columns.indexOf(name);
    assert.ok(i >= 0, 'unknown column: ' + name);
    return i;
  }
  getString(i) { return String(this.rows[this.index][this.columns[i]]); }
  getLong(i) { return Number(this.rows[this.index][this.columns[i]]); }
  close() { this.closed = true; }
}
class RdbPredicates {
  constructor(table) { this.table = table; this.filters = []; this.order = null; }
  equalTo(column, value) { this.filters.push([column, value]); return this; }
  orderByDesc(column) { this.order = { column: column, desc: true }; return this; }
}
class FakeRdbStore {
  constructor() { this.tables = { favorites: [], history: [], notes: [] }; this.version = 0; this.ddl = []; }
  async executeSql(sql) { this.ddl.push(sql); }
  match(pred) {
    return this.tables[pred.table].filter(row => pred.filters.every(([c, v]) => row[c] === v));
  }
  async query(pred, columns) {
    let rows = this.match(pred);
    if (pred.order) {
      const { column, desc } = pred.order;
      rows = rows.slice().sort((a, b) => desc ? b[column] - a[column] : a[column] - b[column]);
    }
    return new ResultSet(rows, columns && columns.length ? columns : COLUMNS[pred.table]);
  }
  async insert(table, bucket) {
    assert.ok(!this.tables[table].some(row => row.id === bucket.id), 'duplicate insert: ' + bucket.id);
    this.tables[table].push(Object.assign({}, bucket));
    return this.tables[table].length;
  }
  async update(bucket, pred) {
    let count = 0;
    for (const row of this.match(pred)) { Object.assign(row, bucket); count++; }
    return count;
  }
  async delete(pred) {
    const target = pred.table;
    const before = this.tables[target].length;
    this.tables[target] = this.tables[target].filter(row => !pred.filters.every(([c, v]) => row[c] === v));
    return before - this.tables[target].length;
  }
}
let currentDb = null;
let uuidSeq = 0;
const arkData = {
  relationalStore: {
    SecurityLevel: { S1: 1, S2: 2, S3: 3, S4: 4 },
    RdbPredicates,
    RdbStore: FakeRdbStore,
    getRdbStore: async () => currentDb
  }
};

const anatomy = loadTypeScript('../entry/src/main/ets/model/Anatomy.ts', {});
const rules = loadTypeScript('../entry/src/main/ets/model/AnatomyRules.ts', { './Anatomy': anatomy });
const { AnatomyStore } = loadTypeScript('../entry/src/main/ets/store/AnatomyStore.ets', {
  '../model/Anatomy': anatomy,
  '../model/AnatomyRules': rules,
  '@kit.ArkData': arkData,
  '@kit.ArkTS': { util: { generateRandomUUID: () => 'note-' + (++uuidSeq) } },
  '@kit.AbilityKit': {}
});

// 单调时钟，避免同一毫秒内多次写入导致时间戳不可区分。
let clock = 1700000000000;
const realDateNow = Date.now;
async function withClock(run) {
  clock = 1700000000000;
  Date.now = () => clock++;
  try { return await run(); } finally { Date.now = realDateNow; }
}

let checks = 0;
async function check(name, run) {
  currentDb = new FakeRdbStore();
  uuidSeq = 0;
  await run();
  checks++;
  console.log('PASS ' + name);
}
function structure(id, name, systemId) { return { id, name, systemId }; }

async function main() {
  // ================= 纯规则 =================
  await check('normalizeStructure 去空白并对空 id/name 返回 null', () => {
    assert.deepEqual(rules.normalizeStructure('  h1 ', ' 心脏 ', ' circulatory '),
      structure('h1', '心脏', 'circulatory'));
    assert.equal(rules.normalizeStructure('', '心脏', 'x'), null);
    assert.equal(rules.normalizeStructure('h1', '   ', 'x'), null);
    assert.equal(rules.normalizeStructure(undefined, undefined, undefined), null);
  });

  await check('readLocateParams 仅需 locateId，缺省时返回 null', () => {
    assert.equal(rules.readLocateParams(null), null);
    assert.equal(rules.readLocateParams({}), null);
    assert.deepEqual(rules.readLocateParams({ locateId: ' h1 ', locateSystemId: ' s ' }),
      structure('h1', '', 's'));
    assert.deepEqual(rules.readLocateParams({ locateId: 'h1', locateName: '心脏' }),
      structure('h1', '心脏', ''));
  });

  await check('buildLocateParams 生成定位参数，空结构返回空对象', () => {
    assert.deepEqual(rules.buildLocateParams(structure('h1', '心脏', 's')),
      { locateId: 'h1', locateName: '心脏', locateSystemId: 's' });
    assert.deepEqual(rules.buildLocateParams(null), {});
  });

  await check('isValidNoteContent 拒绝空/超长正文', () => {
    assert.equal(rules.isValidNoteContent('一条笔记'), true);
    assert.equal(rules.isValidNoteContent('   '), false);
    assert.equal(rules.isValidNoteContent(''), false);
    assert.equal(rules.isValidNoteContent('x'.repeat(rules.NOTE_MAX_LENGTH)), true);
    assert.equal(rules.isValidNoteContent('x'.repeat(rules.NOTE_MAX_LENGTH + 1)), false);
  });

  await check('favoriteAction 依据当前状态给出增/删动作', () => {
    assert.equal(rules.favoriteAction(false), rules.FavoriteAction.Add);
    assert.equal(rules.favoriteAction(true), rules.FavoriteAction.Remove);
  });

  await check('planHistoryWrite 新增与更新两种计划', () => {
    const fresh = rules.planHistoryWrite(null, structure('h1', '心脏', 's'), 100);
    assert.equal(fresh.isNew, true);
    assert.deepEqual(fresh.row, { id: 'h1', name: '心脏', systemId: 's', visitedAt: 100 });
    const existing = { id: 'h1', name: '旧名', systemId: 'old', visitedAt: 10 };
    const updated = rules.planHistoryWrite(existing, structure('h1', '心脏', 's'), 200);
    assert.equal(updated.isNew, false);
    assert.deepEqual(updated.row, { id: 'h1', name: '心脏', systemId: 's', visitedAt: 200 });
  });

  await check('overflowHistoryIds 按降序保留前 limit 条', () => {
    const rows = [1, 2, 3, 4, 5].map(n => ({ id: 'h' + n, name: '', systemId: '', visitedAt: n }));
    assert.deepEqual(rules.overflowHistoryIds(rows, 3), ['h4', 'h5']);
    assert.deepEqual(rules.overflowHistoryIds(rows, 5), []);
    assert.deepEqual(rules.overflowHistoryIds(rows, 0), ['h1', 'h2', 'h3', 'h4', 'h5']);
  });

  await check('planNoteWrite 新建 / 编辑保留 createdAt', () => {
    const fresh = rules.planNoteWrite(null, 'n1', 'h1', '心脏', '  正文  ', 500);
    assert.equal(fresh.isNew, true);
    assert.deepEqual(fresh.note,
      { id: 'n1', structureId: 'h1', structureName: '心脏', content: '正文', createdAt: 500, updatedAt: 500 });
    const existing = { id: 'n1', structureId: 'h1', structureName: '心脏', content: '旧', createdAt: 100, updatedAt: 100 };
    const edited = rules.planNoteWrite(existing, 'ignored', 'h1', '心脏', '新内容', 900);
    assert.equal(edited.isNew, false);
    assert.equal(edited.note.id, 'n1');
    assert.equal(edited.note.createdAt, 100);
    assert.equal(edited.note.updatedAt, 900);
    assert.equal(edited.note.content, '新内容');
  });

  await check('formatTime / formatDate 输出稳定', () => {
    const ts = new Date(2026, 9, 15, 9, 5).getTime();
    assert.equal(anatomy.formatTime(ts), '2026-10-15 09:05');
    assert.equal(anatomy.formatDate(ts), '2026-10-15');
  });

  // ================= 存储层 =================
  await check('收藏：新增、重复受控、切换与取消，重启后保留', () => withClock(async () => {
    const a = await AnatomyStore.open({});
    assert.equal(await a.addFavorite('h1', '心脏', 's', '循环系统'), true);
    assert.equal(await a.addFavorite('h1', '心脏', 's', '循环系统'), false, '重复收藏应被拒绝');
    assert.equal(await a.addFavorite('', '空', 's', 'x'), false, '非法结构不应写入');
    assert.equal(currentDb.tables.favorites.length, 1);
    assert.equal(await a.isFavorite('h1'), true);
    // 重启：新的 store 实例读取同一数据库
    const b = await AnatomyStore.open({});
    const favs = await b.listFavorites();
    assert.equal(favs.length, 1);
    assert.equal(favs[0].systemName, '循环系统');
    // 切换：已收藏 → 取消；再次切换 → 重新收藏
    assert.equal(await b.toggleFavorite('h1', '心脏', 's', '循环系统'), false);
    assert.equal(await b.isFavorite('h1'), false);
    assert.equal(await b.toggleFavorite('h1', '心脏', 's', '循环系统'), true);
    assert.equal(await b.isFavorite('h1'), true);
    assert.equal(await b.removeFavorite('missing'), false, '取消不存在的收藏应返回 false');
  }));

  await check('历史：同结构只保留最新一次，按时间倒序，可清空', () => withClock(async () => {
    const s = await AnatomyStore.open({});
    assert.equal(await s.addHistory('h1', '心脏', 's'), true);
    const first = (await s.listHistory())[0].visitedAt;
    assert.equal(await s.addHistory('h1', '心脏-更新', 's'), true, '再次浏览应更新而非新增');
    assert.equal(await s.addHistory('h2', '肺', 's'), true);
    assert.equal(await s.addHistory('', '非法', 's'), false);
    const rows = await s.listHistory();
    assert.equal(rows.length, 2);
    assert.equal(rows[0].id, 'h2', '最新访问应排在最前');
    const refreshed = rows.find(r => r.id === 'h1');
    assert.equal(refreshed.name, '心脏-更新');
    assert.ok(refreshed.visitedAt >= first, '访问时间应被刷新');
    await s.clearHistory();
    assert.deepEqual(await s.listHistory(), []);
  }));

  await check('历史超过上限时淘汰最旧记录', () => withClock(async () => {
    const s = await AnatomyStore.open({});
    const total = rules.HISTORY_LIMIT + 5;
    for (let i = 0; i < total; i++) await s.addHistory('h' + i, '结构' + i, 's');
    const rows = await s.listHistory();
    assert.equal(rows.length, rules.HISTORY_LIMIT);
    assert.equal(rows[0].id, 'h' + (total - 1), '最新的应保留');
    assert.ok(!rows.some(r => r.id === 'h0'), '最旧的应被淘汰');
  }));

  await check('笔记：按结构关联、编辑保留 createdAt、非法内容与非法结构被拒', () => withClock(async () => {
    const s = await AnatomyStore.open({});
    const created = await s.saveNote(null, 'h1', '心脏', '  第一条  ');
    assert.equal(created.content, '第一条');
    assert.equal(created.structureId, 'h1');
    assert.equal(created.createdAt, created.updatedAt);
    await s.saveNote(null, 'h2', '肺', '第二结构笔记');
    await s.saveNote(null, 'h1', '心脏', '心脏第二条');
    const heartNotes = await s.listNotes('h1');
    assert.equal(heartNotes.length, 2, '只返回指定结构的笔记');
    assert.ok(heartNotes.every(n => n.structureId === 'h1'));
    assert.equal((await s.listNotes()).length, 3);

    const edited = await s.saveNote(created.id, 'h1', '心脏', '已修改');
    assert.equal(edited.id, created.id);
    assert.equal(edited.createdAt, created.createdAt, '编辑不应改变创建时间');
    assert.ok(edited.updatedAt > created.updatedAt, '编辑应更新 updatedAt');
    assert.equal((await s.listNotes('h1')).find(n => n.id === created.id).content, '已修改');

    await assert.rejects(() => s.saveNote(null, 'h1', '心脏', '   '), /笔记正文/);
    await assert.rejects(() => s.saveNote(null, '', '', '内容'), /有效结构/);
    assert.equal(await s.deleteNote('missing'), false);
    assert.equal(await s.deleteNote(created.id), true);
    assert.equal((await s.listNotes('h1')).length, 1);
  }));

  await check('收藏 / 历史 / 笔记互不干扰，重启后数据完整', () => withClock(async () => {
    const s = await AnatomyStore.open({});
    await s.addFavorite('h1', '心脏', 's', '循环系统');
    await s.addHistory('h1', '心脏', 's');
    await s.saveNote(null, 'h1', '心脏', '复盘：左心室壁最厚');
    const reopened = await AnatomyStore.open({});
    assert.equal((await reopened.listFavorites()).length, 1);
    assert.equal((await reopened.listHistory()).length, 1);
    const notes = await reopened.listNotes('h1');
    assert.equal(notes.length, 1);
    assert.equal(notes[0].content, '复盘：左心室壁最厚');
  }));

  console.log(`\n${checks} anatomy data tests passed.`);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
