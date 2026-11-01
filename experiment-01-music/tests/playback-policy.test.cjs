const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

// Reuse DevEco's compiler so these tests require no project dependencies.
const studio = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(studio,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/model/PlaybackPolicy.ts'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const sandbox = { exports: {} };
vm.runInNewContext(compiled, sandbox);
const { PlayMode, nextTrackIndex, previousTrackIndex, formatTime } = sandbox.exports;

test('empty queues never select a song', () => {
  for (const mode of [PlayMode.Sequential, PlayMode.Random, PlayMode.SingleRepeat]) {
    assert.equal(nextTrackIndex(0, 0, mode, true), -1);
    assert.equal(nextTrackIndex(0, 0, mode, false), -1);
  }
  assert.equal(previousTrackIndex(0, 0), -1);
});

test('sequential completion stops at the end; manual navigation wraps', () => {
  assert.equal(nextTrackIndex(0, 3, PlayMode.Sequential, false), 1);
  assert.equal(nextTrackIndex(2, 3, PlayMode.Sequential, false), -1);
  assert.equal(nextTrackIndex(2, 3, PlayMode.Sequential, true), 0);
  assert.equal(previousTrackIndex(0, 3), 2);
  assert.equal(previousTrackIndex(2, 3), 1);
});

test('single repeat repeats on completion but allows manual next', () => {
  assert.equal(nextTrackIndex(1, 3, PlayMode.SingleRepeat, false), 1);
  assert.equal(nextTrackIndex(1, 3, PlayMode.SingleRepeat, true), 2);
  assert.equal(nextTrackIndex(2, 3, PlayMode.SingleRepeat, true), 0);
});

test('random mode can reach every other song and never immediately repeats', () => {
  for (let current = 0; current < 5; current++) {
    const selected = new Set();
    for (let sample = 0; sample <= 100; sample++) {
      const next = nextTrackIndex(current, 5, PlayMode.Random, false, sample / 100);
      assert.ok(next >= 0 && next < 5);
      assert.notEqual(next, current);
      selected.add(next);
    }
    assert.equal(selected.size, 4);
  }
});

test('one-song queues follow each mode and navigation remains valid', () => {
  assert.equal(nextTrackIndex(0, 1, PlayMode.Sequential, false), -1);
  assert.equal(nextTrackIndex(0, 1, PlayMode.Random, false), 0);
  assert.equal(nextTrackIndex(0, 1, PlayMode.SingleRepeat, false), 0);
  assert.equal(previousTrackIndex(0, 1), 0);
});

test('unselected or stale queue indices recover to the first song', () => {
  assert.equal(nextTrackIndex(-1, 3, PlayMode.Sequential, true), 0);
  assert.equal(nextTrackIndex(5, 3, PlayMode.Random, false), 0);
  assert.equal(previousTrackIndex(-1, 3), 0);
});

test('time formatting truncates fractions and safely handles unknown duration', () => {
  assert.equal(formatTime(0), '0:00');
  assert.equal(formatTime(59999), '0:59');
  assert.equal(formatTime(61000), '1:01');
  assert.equal(formatTime(3600000), '60:00');
  assert.equal(formatTime(-1000), '0:00');
  assert.equal(formatTime(NaN), '0:00');
  assert.equal(formatTime(Infinity), '0:00');
});
