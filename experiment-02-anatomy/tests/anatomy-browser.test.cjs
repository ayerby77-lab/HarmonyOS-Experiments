// 人体浏览模块测试：
// 1) bridge/AtlasResources.ts —— 离线资源路径映射（纯函数）；
// 2) bridge/AnatomySession.ets —— 就绪前定位排队 / 就绪后补发、搜索别名、
//    结构选中事件、系统切换、加载错误。
// 会话层依赖 @kit.ArkWeb，这里注入一个 WebviewController 桩，观察其收到脚本后
// 驱动回调，从而在无 HarmonyOS 运行时的环境下评测排队与回传逻辑。
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
  const filename = path.resolve(__dirname, '..', relativePath);
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true,
    fileName: filename.replace(/\.ets$/, '.ts')
  });
  assert.equal(result.diagnostics.length, 0,
    relativePath + ' 转译诊断: ' + JSON.stringify(result.diagnostics.map(d => d.messageText)));
  const loaded = new Module(filename, module);
  loaded.require = id => {
    assert.ok(Object.hasOwn(imports, id), 'Unexpected dependency: ' + id);
    return imports[id];
  };
  loaded._compile(result.outputText, filename);
  return loaded.exports;
}

const tick = () => new Promise(resolve => setTimeout(resolve, 0));
let passed = 0;
async function ok(name, fn) {
  await fn();
  passed += 1;
  console.log('PASS ' + name);
}

// ---- 1. 资源路径映射 ----
const res = loadTypeScript('entry/src/main/ets/bridge/AtlasResources.ts', {});

async function run() {
  await ok('mapRawfilePath 相对路径补全 human-atlas 前缀', () => {
    assert.equal(res.mapRawfilePath('./assets/index-1ie-Jbum.js'), 'human-atlas/assets/index-1ie-Jbum.js');
    assert.equal(res.mapRawfilePath('./models/atlas.json'), 'human-atlas/models/atlas.json');
  });

  await ok('mapRawfilePath 根路径分块重映射到 human-atlas 下', () => {
    assert.equal(res.mapRawfilePath('resource://rawfile/models/body-0.bin.gz'),
      'human-atlas/models/body-0.bin.gz');
    assert.equal(res.mapRawfilePath('/models/body-3.bin'), 'human-atlas/models/body-3.bin');
  });

  await ok('mapRawfilePath 处理 http(s)/file scheme 与查询、锚点', () => {
    assert.equal(res.mapRawfilePath('https://example.com/human-atlas/index.html'),
      'human-atlas/index.html');
    assert.equal(res.mapRawfilePath('resource://rawfile/human-atlas/index.html?x=1#frag'),
      'human-atlas/index.html');
  });

  await ok('mapRawfilePath 拒绝目录穿越与空路径', () => {
    assert.equal(res.mapRawfilePath('../../secret.txt'), '');
    assert.equal(res.mapRawfilePath('human-atlas/../secret'), '');
    assert.equal(res.mapRawfilePath(''), '');
    assert.equal(res.mapRawfilePath('https://example.com'), '');
  });

  await ok('mimeOfPath 按扩展名给出 MIME', () => {
    assert.equal(res.mimeOfPath('human-atlas/index.html'), 'text/html');
    assert.equal(res.mimeOfPath('human-atlas/assets/index.js'), 'text/javascript');
    assert.equal(res.mimeOfPath('human-atlas/assets/index.css'), 'text/css');
    assert.equal(res.mimeOfPath('human-atlas/models/atlas.json'), 'application/json');
    assert.equal(res.mimeOfPath('human-atlas/models/body-0.bin.gz'), 'application/gzip');
    assert.equal(res.mimeOfPath('human-atlas/models/body-0.bin'), 'application/octet-stream');
  });

  // ---- 2. 会话层排队与回传 ----
  class FakeController {
    constructor() {
      this.calls = [];
      this.responder = () => 'true';
    }
    runJavaScript(expr) {
      this.calls.push(expr);
      return Promise.resolve(this.responder(expr));
    }
  }

  const webview = { WebviewController: FakeController };
  const bridgeMod = loadTypeScript('entry/src/main/ets/bridge/AnatomyBridge.ets', {});
  const modelMod = loadTypeScript('entry/src/main/ets/model/Anatomy.ts', {});
  const sessionMod = loadTypeScript('entry/src/main/ets/bridge/AnatomySession.ets', {
    '@kit.ArkWeb': { webview },
    '../model/Anatomy': modelMod,
    './AnatomyBridge': bridgeMod
  });

  const session = sessionMod.AnatomySession.shared();
  const controller = new FakeController();
  const bridge = session.getBridge();
  const results = [];
  session.onLocateResult((result, target) => results.push([result, target]));

  await ok('会话单例唯一', () => {
    assert.equal(sessionMod.AnatomySession.shared(), session);
  });

  await ok('未就绪时 locate 返回 queued 且不执行脚本', () => {
    session.bindController(controller);
    session.resetLoad();
    assert.equal(session.isReady(), false);
    assert.equal(session.locate('FJ1252'), 'queued');
    assert.equal(controller.calls.length, 0, '就绪前不应执行 selectPart');
    assert.deepEqual(results, [['queued', 'FJ1252']]);
  });

  await ok('就绪前重复定位同一 ID 只登记一次', () => {
    session.locate('FJ1252');
    assert.equal(controller.calls.length, 0);
  });

  await ok('桥接就绪后补发排队请求且只补发一次', async () => {
    bridge.onBridgeReady();
    bridge.onProgressChange(100);
    assert.equal(session.isReady(), true);
    assert.equal(session.snapshot().state, 'ready');
    await tick();
    const selects = controller.calls.filter(c => c.indexOf('selectPart') >= 0);
    assert.equal(selects.length, 1, '排队请求应只补发一次: ' + JSON.stringify(controller.calls));
    assert.ok(selects[0].indexOf('FJ1252') >= 0, '补发应携带结构 ID');
    assert.deepEqual(results[results.length - 1], ['found', 'FJ1252']);
  });

  await ok('中文搜索走英文别名并定位', () => {
    assert.equal(session.search('心脏'), 'sent');
    const last = controller.calls[controller.calls.length - 1];
    assert.ok(last.indexOf('search') >= 0 && last.indexOf('"heart"') >= 0,
      '中文关键词应转换为 heart: ' + last);
  });

  await ok('英文搜索原样透传', () => {
    assert.equal(session.search('femur'), 'sent');
    const last = controller.calls[controller.calls.length - 1];
    assert.ok(last.indexOf('"femur"') >= 0);
  });

  await ok('空查询被拒绝', () => {
    assert.equal(session.search('   '), 'rejected');
  });

  await ok('Web 回传结构选中并补全系统名与颜色', () => {
    const got = [];
    const listener = sel => got.push(sel);
    session.onSelection(listener);
    bridge.onStructureSelected('FJ1', 'Left ventricle', 'cardiac');
    assert.equal(got.length, 1);
    assert.equal(got[0].id, 'FJ1');
    assert.equal(got[0].name, 'Left ventricle');
    assert.equal(got[0].systemName, '心脏');
    assert.equal(got[0].systemColor, '#b96760');
    bridge.onStructureSelected('C9', 'Mitral valve', 'concept');
    assert.equal(got[1].systemName, '解剖概念');
    session.offSelection(listener);
  });

  await ok('系统切换更新可见集合并下发指令', () => {
    assert.ok(session.visibleSystems().indexOf('skeletal') >= 0);
    session.toggleSystem('skeletal', false);
    assert.equal(session.visibleSystems().indexOf('skeletal'), -1);
    session.toggleSystem('skeletal', true);
    assert.ok(session.visibleSystems().indexOf('skeletal') >= 0);
    const last = controller.calls[controller.calls.length - 1];
    assert.ok(last.indexOf('toggleSystem') >= 0 && last.indexOf('"skeletal"') >= 0 &&
      last.indexOf('true') >= 0);
  });

  await ok('默认可见系统共 15 个且不含体表', () => {
    assert.equal(sessionMod.DEFAULT_VISIBLE_SYSTEM_IDS.indexOf('integumentary'), -1);
    assert.equal(sessionMod.ANATOMY_SYSTEMS.length, 15);
  });

  await ok('加载错误进入 error 并拒绝定位', () => {
    bridge.onWebError('目录读取失败');
    assert.equal(session.snapshot().state, 'error');
    assert.equal(session.snapshot().message, '目录读取失败');
    assert.equal(session.locate('FJ9'), 'rejected');
  });

  session.unbindController();
  console.log('\n' + passed + ' anatomy browser tests passed.');
}

run().catch(error => {
  console.error('FAIL ' + (error && error.stack ? error.stack : error));
  process.exit(1);
});
