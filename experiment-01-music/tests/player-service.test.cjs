const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const studio = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.join(__dirname, '../entry/src/main/ets');
const tick = () => new Promise(resolve => setImmediate(resolve));
function load(file, imports = {}) {
  const code = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const context = { exports: {}, require: name => {
    assert.ok(name in imports, `Unexpected import ${name}`);
    return imports[name];
  }, setTimeout, clearTimeout };
  vm.runInNewContext(code, context);
  return context.exports;
}
const policy = load('model/PlaybackPolicy.ts');
function harness() {
  const players = [];
  const opened = [];
  const closed = [];
  const snapshots = [];
  const failures = new Set();
  class MockPlayer {
    state = 'idle';
    duration = 36000;
    handlers = new Map();
    volumes = [];
    seeks = [];
    released = false;
    on(event, handler) { this.handlers.set(event, handler); }
    off(event) { this.handlers.delete(event); }
    emit(event, value) { this.handlers.get(event)?.(value); }
    transition(state) { this.state = state; this.emit('stateChange', state); }
    set fdSrc(value) {
      this.source = value;
      setImmediate(() => this.transition('initialized'));
    }
    async prepare() { await tick(); this.transition('prepared'); }
    async play() { await tick(); this.transition('playing'); }
    async pause() { await tick(); this.transition('paused'); }
    async release() { await tick(); this.released = true; }
    seek(value) { this.seeks.push(value); setImmediate(() => this.emit('seekDone', value)); }
    setVolume(value) { this.volumes.push(value); }
  }
  const resources = {
    async getRawFd(name) {
      await tick();
      if (failures.has(name)) throw Object.assign(new Error('missing resource'), { code: 404 });
      opened.push(name);
      return { fd: opened.length, offset: 0, length: 100 };
    },
    async closeRawFd(name) { await tick(); closed.push(name); }
  };
  const { PlayerService } = load('services/PlayerService.ets', {
    '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_ONLY: 0 }, async open(path) { opened.push(path); return { fd: opened.length }; }, async stat() { return { size: 100 }; }, async close(file) { closed.push(`fd:${file.fd}`); } } },
    '@kit.MediaKit': { media: { async createAVPlayer() { const player = new MockPlayer(); players.push(player); return player; } } },
    '@kit.AudioKit': { audio: { InterruptHint: {} } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '../model/PlaybackPolicy': policy
  });
  const tracks = ['a.wav', 'b.wav', 'c.wav'].map(resource => ({ resource }));
  const service = new PlayerService(resources, tracks, snapshot => snapshots.push(snapshot));
  async function settle() {
    // A completion callback can append another operation while the current one resolves.
    for (let round = 0; round < 4; round++) { await service.commands; await tick(); }
  }
  return { service, players, opened, closed, failures, snapshots, settle,
    latest: () => snapshots.at(-1), player: () => players.at(-1) };
}

test('rapid selection and next commands execute in order and close old descriptors', async () => {
  const h = harness();
  h.service.initialize(); h.service.select(1); h.service.next(); h.service.next();
  await h.settle();
  assert.deepEqual(h.opened, ['a.wav', 'b.wav', 'c.wav', 'a.wav']);
  assert.deepEqual(h.closed, ['a.wav', 'b.wav', 'c.wav']);
  assert.equal(h.latest().index, 0);
  assert.equal(h.latest().playing, true);
  assert.equal(h.latest().busy, false);
  assert.ok(h.players.slice(0, -1).every(player => player.released));
  h.service.dispose(); await h.settle();
});

test('initialize prepares silently; toggle plays and pauses; seek follows confirmation', async () => {
  const h = harness(); h.service.initialize(); await h.settle();
  assert.equal(h.latest().ready, true); assert.equal(h.latest().playing, false);
  h.service.toggle(); await h.settle(); assert.equal(h.latest().playing, true);
  h.service.toggle(); await h.settle(); assert.equal(h.latest().playing, false);
  h.service.seek(12345.6); await h.settle(); assert.equal(h.latest().position, 12346);
  h.service.seek(999999); await h.settle(); assert.equal(h.latest().position, 36000);
  h.service.seek(-10); await h.settle(); assert.equal(h.latest().position, 0);
  h.service.dispose(); await h.settle();
});

test('volume clamps and persists across track switches', async () => {
  const h = harness(); h.service.initialize(); await h.settle();
  h.service.setVolume(35); assert.equal(h.player().volumes.at(-1), 0.35);
  h.service.next(); await h.settle(); assert.equal(h.player().volumes.at(-1), 0.35);
  h.service.setVolume(120); assert.equal(h.latest().volume, 1);
  h.service.setVolume(-20); assert.equal(h.latest().volume, 0);
  h.service.dispose(); await h.settle();
});

test('sequential completion advances and stops at the final track', async () => {
  const h = harness(); h.service.select(1); await h.settle();
  h.player().transition('completed'); await h.settle(); assert.equal(h.latest().index, 2);
  const count = h.players.length;
  h.player().transition('completed'); await h.settle();
  assert.equal(h.players.length, count); assert.equal(h.latest().playing, false);
  assert.equal(h.latest().position, h.latest().duration);
  h.service.dispose(); await h.settle();
});

test('random skips current track; repeat replays current; manual next still advances', async () => {
  const h = harness(); h.service.select(1); await h.settle();
  h.service.cycleMode(); assert.equal(h.latest().mode, policy.PlayMode.Random);
  h.player().transition('completed'); await h.settle(); assert.notEqual(h.latest().index, 1);
  h.service.cycleMode(); const repeated = h.latest().index;
  h.player().transition('completed'); await h.settle();
  assert.equal(h.latest().index, repeated); assert.equal(h.latest().playing, true);
  h.service.next(); await h.settle(); assert.equal(h.latest().index, (repeated + 1) % 3);
  h.service.cycleMode(); assert.equal(h.latest().mode, policy.PlayMode.Sequential);
  h.service.dispose(); await h.settle();
});

test('dispose releases the active player and descriptor and suppresses further commands', async () => {
  const h = harness(); h.service.initialize(); await h.settle();
  const before = h.snapshots.length;
  h.service.dispose(); h.service.select(2); await h.settle();
  assert.equal(h.player().released, true); assert.deepEqual(h.closed, ['a.wav']);
  assert.equal(h.snapshots.length, before); assert.equal(h.players.length, 1);
});

test('a failed load reports an error and subsequent selection recovers', async () => {
  const h = harness(); h.failures.add('a.wav'); h.service.initialize(); await h.settle();
  assert.match(h.latest().error, /404/); assert.equal(h.latest().busy, false);
  assert.equal(h.latest().ready, false);
  h.service.select(1); await h.settle();
  assert.equal(h.latest().error, ''); assert.equal(h.latest().playing, true);
  assert.equal(h.latest().index, 1); assert.equal(h.players[0].released, true);
  h.service.dispose(); await h.settle(); assert.deepEqual(h.closed, ['b.wav']);
});

// Local music uses file descriptors, while packaged demo songs keep the resource path.
test('local queue uses file descriptors and releases them on switching and disposal', async () => {
  const h = harness();
  const tracks = [{ id: 'local-a', path: '/music/a.mp3', resource: '' },
    { id: 'local-b', path: '/music/b.mp3', resource: '' }];
  h.service.setQueue(tracks); await h.settle();
  assert.equal(h.latest().track.id, 'local-a');
  assert.equal(h.latest().playing, true);
  h.service.next(); await h.settle();
  assert.equal(h.latest().track.id, 'local-b');
  assert.deepEqual(h.opened, ['/music/a.mp3', '/music/b.mp3']);
  assert.deepEqual(h.closed, ['fd:1']);
  h.service.dispose(); await h.settle();
  assert.deepEqual(h.closed, ['fd:1', 'fd:2']);
});
