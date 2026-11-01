const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { test } = require('node:test');
const { DatabaseSync } = require('node:sqlite');
const studio = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/services/PlaylistStore.ets'), 'utf8');
const code = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
function harness(directory) {
  let openResults = 0;
  const relationalStore = {
    SecurityLevel: { S1: 1 },
    async getRdbStore(_context, config) {
      const db = new DatabaseSync(path.join(directory, config.name));
      return {
        async executeSql(sql, args = []) { db.prepare(sql).run(...args); },
        async querySql(sql, args = []) {
          const statement = db.prepare(sql);
          statement.setReturnArrays(true);
          const rows = statement.all(...args);
          let index = -1;
          let closed = false;
          openResults++;
          return {
            goToNextRow() { return ++index < rows.length; },
            getLong(column) { return rows[index][column]; },
            getString(column) { return rows[index][column]; },
            close() { assert.equal(closed, false); closed = true; openResults--; }
          };
        },
        async close() { db.close(); }
      };
    }
  };
  const context = { exports: {}, $r: name => ({ resource: name }), require: name => {
    assert.equal(name, '@kit.ArkData');
    return { relationalStore };
  } };
  vm.runInNewContext(code, context);
  return { store: new context.exports.PlaylistStore(), checkResults() { assert.equal(openResults, 0); } };
}
const track = { id: '/music/一首歌.mp3', title: "Don't stop", artist: '歌手', album: '专辑',
  cover: '/music/cover.jpg', resource: '', path: '/music/一首歌.mp3', fileName: '一首歌.mp3', duration: 120000 };
test('actual store SQL persists metadata across reopen, handles duplicate membership and cascades deletion', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'music-rdb-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  let h = harness(directory);
  await h.store.initialize({});
  await h.store.create('  收藏  ');
  const first = (await h.store.list())[0];
  assert.equal(first.name, '收藏');
  await h.store.addTrack(first.id, track);
  await h.store.addTrack(first.id, track);
  assert.equal((await h.store.list())[0].count, 1);
  h.checkResults();
  await h.store.close();
  h = harness(directory);
  await h.store.initialize({});
  assert.deepEqual(JSON.parse(JSON.stringify(await h.store.tracks(first.id))), [track]);
  await h.store.create("other'; DROP TABLE playlists; --");
  const second = (await h.store.list())[1];
  await h.store.addTrack(second.id, track);
  await h.store.removeTrack(first.id, track.id);
  assert.equal((await h.store.tracks(first.id)).length, 0);
  assert.equal((await h.store.tracks(second.id)).length, 1);
  await h.store.remove(second.id);
  assert.equal((await h.store.tracks(second.id)).length, 0);
  await assert.rejects(h.store.addTrack(second.id, track), /FOREIGN KEY/);
  assert.equal((await h.store.list()).length, 1);
  h.checkResults();
  await h.store.close();
});
test('validates names, protects duplicate names, restores default covers and demo tracks', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'music-rdb-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const h = harness(directory);
  await h.store.initialize({});
  await assert.rejects(h.store.create('   '), /1至40/);
  await assert.rejects(h.store.create('a'.repeat(41)), /1至40/);
  await h.store.create('收藏');
  await assert.rejects(h.store.create(' 收藏 '), /已存在/);
  const playlist = (await h.store.list())[0];
  await h.store.addTrack(playlist.id, { ...track, id: 'demo', path: undefined, cover: {}, resource: 'demo.wav' });
  const restored = (await h.store.tracks(playlist.id))[0];
  assert.equal(restored.cover.resource, 'app.media.cover_default');
  assert.equal(restored.resource, 'demo.wav');
  assert.equal(restored.path, undefined);
  h.checkResults();
  await h.store.close();
  await h.store.close();
  await assert.rejects(h.store.list(), /尚未就绪/);
});
