const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const studio = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/model/Lyrics.ts'), 'utf8');
const sandbox = { exports: {} };
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText, sandbox);
const { parseLrc, locateLyric, locateGlyph } = sandbox.exports;
const plain = value => JSON.parse(JSON.stringify(value));

test('standard fractional stamps, metadata and invalid lines', () => {
  const lines = parseLrc('[ar:Artist]\n[00:60]bad\n[abc]bad\n[00:01.2]甲乙\r\n[00:03.045]丙\n[00:04.12]丁', 5000);
  assert.deepEqual(plain(lines.map(l => l.start)), [1200, 3045, 4120]);
  assert.equal(lines[0].text, '甲乙');
  assert.equal(lines[0].precise, false);
  assert.equal(lines[0].glyphs[1].start, 2122.5);
  assert.equal(lines[2].end, 5000);
  assert.equal(parseLrc('[00:01.2345]bad\n[00:xx]bad', 10000).length, 0);
});
test('multiple timestamps and duplicates sort stably with strictly later ends', () => {
  const lines = parseLrc('[00:04][00:01]重复\n[00:01]第二\n[00:06]尾', 0);
  assert.deepEqual(plain(lines.map(l => l.text)), ['重复', '第二', '重复', '尾']);
  assert.deepEqual(plain(lines.map(l => l.end)), [4000, 4000, 6000, 11000]);
  assert.equal(locateLyric(lines, 1000), 1);
});
test('global signed offset applies even after lyrics and clamps negative starts', () => {
  assert.equal(parseLrc('[00:01]字\n[offset:+300]', 5000)[0].start, 1300);
  const line = parseLrc('[00:01]<00:01>字<00:02>尾\n[offset:-1500]', 5000)[0];
  assert.equal(line.start, 0);
  assert.equal(line.glyphs[0].start, 0);
  assert.equal(line.glyphs[1].start, 500);
});
test('enhanced single character timing is precise and final empty tag bounds singing', () => {
  const line = parseLrc('[00:01]<00:01>星<00:02>光<00:03>', 5000)[0];
  assert.equal(line.text, '星光');
  assert.equal(line.precise, true);
  assert.deepEqual(plain(line.glyphs), [{text:'星',start:1000,end:2000},{text:'光',start:2000,end:3000}]);
  assert.equal(locateGlyph(line, 999), -1);
  assert.equal(locateGlyph(line, 2000), 1);
  assert.equal(locateGlyph(line, 3000), -1);
});
test('word segments estimate per character, preserve Unicode and repeated enhanced timestamps', () => {
  const lines = parseLrc('[00:01][00:06]<00:01>你好<00:03>🌟<00:04>', 10000);
  assert.equal(lines[0].precise, false);
  assert.deepEqual(plain(lines[0].glyphs.map(g => g.text)), ['你','好','🌟']);
  assert.deepEqual(plain(lines[0].glyphs.map(g => g.start)), [1000,2000,3000]);
  assert.deepEqual(plain(lines[1].glyphs.map(g => g.start)), [6000,7000,8000]);
});
test('seeking both directions, blank instrumental cue and end boundaries', () => {
  const lines = parseLrc('[00:01]开\n[00:02]\n[00:04]末', 6000);
  assert.equal(locateLyric(lines, 4500), 2);
  assert.equal(locateLyric(lines, 1500), 0);
  assert.equal(locateLyric(lines, 2000), 1);
  assert.equal(lines[1].text, '');
  assert.equal(locateGlyph(lines[1], 3000), -1);
  assert.equal(locateLyric(lines, 999), -1);
  assert.equal(locateLyric(lines, 6000), -1);
  assert.equal(locateLyric(lines, NaN), -1);
  assert.equal(locateGlyph(lines[0], Infinity), -1);
});
test('malformed enhanced tags and out of order tags never produce negative glyph spans', () => {
  const line = parseLrc('[00:02]<00:01>甲<garbage>乙<00:00>丙', 2500)[0];
  assert.equal(line.text, '甲乙丙');
  assert.ok(line.glyphs.every(g => g.start >= line.start && g.end >= g.start && g.end <= line.end));
  const clipped = parseLrc('[00:10]晚', 5000)[0];
  assert.equal(locateGlyph(clipped, 10000), -1);
});
