const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const studio = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/services/LocalLibrary.ets'), 'utf8');
const code = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
function harness() {
  const files = new Map([['/ability/music/A.MP3', 'tagged'], ['/app/music/plain.wav', 'plain'], ['/app/music/readme.txt', 'ignore']]);
  let opened = 0, extractors = 0;
  const io = {
    OpenMode: { READ_ONLY: 1 },
    async access(p) { return p.endsWith('/music') || files.has(p); },
    async listFile(p) { return [...files.keys()].filter(f => f.startsWith(p + '/')).map(f => f.slice(p.length + 1)); },
    async stat(p) { return { size: 100, isFile: () => true }; },
    async open(p) { opened++; return { fd: p }; },
    async close() { opened--; },
    async copyFile(from, to) { files.set(to, files.get(from)); },
    async rename(from, to) { files.set(to, files.get(from)); files.delete(from); }
  };
  let selected = [];
  const media = { async createAVMetadataExtractor() {
    extractors++;
    return {
      async fetchMetadata() {
        if (this.fdSrc.fd.endsWith('.wav')) throw Error('no metadata');
        return { title: 'Song Title', artist: 'Artist', album: 'Album', duration: '123456' };
      },
      async fetchAlbumCover() { throw Error('no image'); },
      async release() { extractors--; }
    };
  } };
  const context = { exports: {}, $r: value => value, require: name => {
    if (name === '@kit.CoreFileKit') return { fileIo: io, picker: { DocumentViewPicker: class { async select() { return selected; } } } };
    if (name === '@kit.MediaKit') return { media };
    if (name === '@kit.ImageKit') return { image: {} };
    throw Error(name);
  } };
  vm.runInNewContext(code, context);
  return { ...context.exports, library: new context.exports.LocalLibrary({ filesDir: '/ability', cacheDir: '/cache', getApplicationContext: () => ({ filesDir: '/app' }) }),
    files, select(uris) { selected = uris; }, check() { assert.equal(opened, 0); assert.equal(extractors, 0); } };
}
test('scans both sandbox roots; metadata and fallback survive extractor failure; all handles released', async () => {
  const h = harness();
  const tracks = await h.library.scan();
  assert.equal(tracks.length, 2);
  assert.equal(tracks[0].title, 'Song Title');
  assert.equal(tracks[0].duration, 123456);
  assert.equal(tracks[1].title, 'plain');
  assert.equal(tracks[1].artist, '未知歌手');
  assert.equal(h.library.warnings.length, 1);
  h.check();
});
test('search matches title artist album filename case-insensitively and trims input', async () => {
  const h = harness(); const tracks = await h.library.scan();
  for (const query of [' SONG ', 'artist', 'ALBUM', 'a.mp3']) assert.equal(h.searchTracks(tracks, query).length, 1);
  assert.equal(h.searchTracks(tracks, 'missing').length, 0);
  assert.equal(h.searchTracks(tracks, ' ').length, 2);
});
test('import persists files once per source, preserves readable names and cancellation retains library', async () => {
  const h = harness(); h.files.set('/downloads/New.mp3', 'new'); h.select(['/downloads/New.mp3']);
  let tracks = await h.library.importFiles();
  assert.equal(tracks.length, 3);
  assert.equal(tracks.find(t => t.fileName === 'New.mp3').path.startsWith('/ability/music/import_'), true);
  tracks = await h.library.importFiles(); assert.equal(tracks.length, 3);
  h.select([]); tracks = await h.library.importFiles(); assert.equal(tracks.length, 3);
  h.check();
});
