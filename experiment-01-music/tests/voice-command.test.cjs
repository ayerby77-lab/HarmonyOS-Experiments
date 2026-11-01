const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const studio = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/model/CommandParser.ts'), 'utf8');
const sandbox = { exports: {} };
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText, sandbox);
const { parseCommand } = sandbox.exports;
const plain = value => JSON.parse(JSON.stringify(value));

test('pause phrases trigger pause, including lone 停 and whitespace variants', () => {
  for (const text of ['暂停', '停止', '停', '停一下', '停下吧', ' 别播了 ']) {
    assert.deepEqual(plain(parseCommand(text)), { type: 'pause' }, `text=${text}`);
  }
});

test('resume phrases trigger resume', () => {
  for (const text of ['继续', '继续播放', '恢复播放', '恢复', '继续播']) {
    assert.deepEqual(plain(parseCommand(text)), { type: 'resume' }, `text=${text}`);
  }
});

test('next phrases trigger next regardless of song vs 曲 wording', () => {
  for (const text of ['下一首', '下一曲', '后一首', '换一首', '下一首歌', '切歌']) {
    assert.deepEqual(plain(parseCommand(text)), { type: 'next' }, `text=${text}`);
  }
});

test('previous phrases trigger previous', () => {
  for (const text of ['上一首', '上一曲', '前一首', '上一首歌']) {
    assert.deepEqual(plain(parseCommand(text)), { type: 'previous' }, `text=${text}`);
  }
});

test('play prefixes capture the trailing song name as query', () => {
  assert.deepEqual(plain(parseCommand('播放突然好想你')), { type: 'playSong', query: '突然好想你' });
  assert.deepEqual(plain(parseCommand('放微风')), { type: 'playSong', query: '微风' });
  assert.deepEqual(plain(parseCommand('我想听夜色')), { type: 'playSong', query: '夜色' });
  assert.deepEqual(plain(parseCommand('我想听一首晨光')), { type: 'playSong', query: '晨光' });
  assert.deepEqual(plain(parseCommand('来一首微风')), { type: 'playSong', query: '微风' });
  assert.deepEqual(plain(parseCommand('来首夜色')), { type: 'playSong', query: '夜色' });
  assert.deepEqual(plain(parseCommand('帮我播放突然好想你')), { type: 'playSong', query: '突然好想你' });
  assert.deepEqual(plain(parseCommand('点歌 突然好想你')), { type: 'playSong', query: '突然好想你' });
});

test('bare play keyword with no song name falls back to resume', () => {
  assert.deepEqual(plain(parseCommand('播放')), { type: 'resume' });
  assert.deepEqual(plain(parseCommand('放')), { type: 'resume' });
  assert.deepEqual(plain(parseCommand('点歌')), { type: 'resume' });
});

test('trailing filler particles are stripped from the captured query', () => {
  assert.deepEqual(plain(parseCommand('播放微风吧')), { type: 'playSong', query: '微风' });
  assert.deepEqual(plain(parseCommand('我想听夜色呢')), { type: 'playSong', query: '夜色' });
  assert.deepEqual(plain(parseCommand('来一首晨光啊')), { type: 'playSong', query: '晨光' });
});

test('precedence: pause beats resume even when both keywords appear', () => {
  // "暂停继续" — pause keyword wins so a confused utterance still halts playback.
  assert.deepEqual(plain(parseCommand('暂停继续')), { type: 'pause' });
  // "继续下一首" — resume wins over next; user wants to keep playing then advance.
  assert.equal(parseCommand('继续下一首').type, 'resume');
  // "下一首上一首" — next wins (leftmost-strongest matching order).
  assert.equal(parseCommand('下一首上一首').type, 'next');
});

test('empty/whitespace-only input is unknown, not pause', () => {
  assert.deepEqual(plain(parseCommand('')), { type: 'unknown', raw: '' });
  assert.deepEqual(plain(parseCommand('   ')), { type: 'unknown', raw: '   ' });
});

test('unrecognized utterance is unknown with raw preserved', () => {
  const text = '今天天气真好';
  const result = parseCommand(text);
  assert.equal(result.type, 'unknown');
  assert.equal(result.raw, text);
});
