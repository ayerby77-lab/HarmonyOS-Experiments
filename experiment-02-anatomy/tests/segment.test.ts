// 资料切分与事件总线单元测试（纯逻辑，可在 Node.js 运行）
// 运行方式：node --experimental-strip-types tests/segment.test.ts
// 或先编译：npx tsc tests/segment.test.ts --outDir /tmp/test-out && node /tmp/test-out/segment.test.js

import { SegmentService } from '../entry/src/main/ets/service/SegmentService';
import { KnowledgeEventBus } from '../entry/src/main/ets/service/KnowledgeEventBus';
import { SEED_DOCUMENTS, SEED_COUNT } from '../entry/src/main/ets/data/SeedDocuments';

let passed = 0;
let failed = 0;

function assert(condition: boolean, message: string): void {
  if (condition) {
    passed++;
    console.log(`  ✓ ${message}`);
  } else {
    failed++;
    console.error(`  ✗ ${message}`);
  }
}

function assertEq(actual: unknown, expected: unknown, message: string): void {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    passed++;
    console.log(`  ✓ ${message}`);
  } else {
    failed++;
    console.error(`  ✗ ${message}`);
    console.error(`    expected: ${JSON.stringify(expected)}`);
    console.error(`    actual:   ${JSON.stringify(actual)}`);
  }
}

// ===== SegmentService 测试 =====
console.log('\n[SegmentService]');

const svc = new SegmentService();

// 测试 1：空内容返回空数组
{
  const segs = svc.split('doc1', 1, '');
  assertEq(segs.length, 0, '空内容返回空片段数组');
}

// 测试 2：短文本不切分，偏移正确
{
  const text = '心脏是中空的肌性器官。';
  const segs = svc.split('doc1', 1, text);
  assertEq(segs.length, 1, '短文本生成 1 个片段');
  assertEq(segs[0].startOffset, 0, '起始偏移为 0');
  assertEq(segs[0].endOffset, text.length, `结束偏移为 ${text.length}`);
  assertEq(segs[0].content, text, '片段内容与原文一致');
  assertEq(segs[0].documentRevision, 1, '片段版本号正确');
  assertEq(segs[0].seqIndex, 0, '顺序索引为 0');
}

// 测试 3：多段落按段落切分
{
  const text = '第一段内容。\n\n第二段内容较长，但仍然在一个段落内。\n\n第三段。';
  const segs = svc.split('doc1', 1, text);
  assertEq(segs.length, 3, '三个段落生成 3 个片段');
  // 验证每个片段的偏移能在原文中找到
  for (const seg of segs) {
    assert(
      text.substring(seg.startOffset, seg.endOffset) === seg.content,
      `片段 #${seg.seqIndex} 偏移映射正确`
    );
  }
}

// 测试 4：长段落按句子切分，偏移连续且不重叠
{
  // 构造超过 MAX_SEGMENT_CHARS 的段落
  let text = '';
  for (let i = 0; i < 30; i++) {
    text += `这是第${i}句话，用来测试长段落的切分行为是否正确。`;
  }
  const segs = svc.split('doc1', 1, text);
  assert(segs.length > 1, `长段落被切分为多个片段（${segs.length} 个）`);

  // 验证所有片段拼接后等于原文
  const reconstructed = segs.map(s => s.content).join('');
  assertEq(reconstructed, text, '所有片段拼接后等于原文');

  // 验证偏移连续且不重叠
  let lastEnd = 0;
  let continuous = true;
  for (const seg of segs) {
    if (seg.startOffset !== lastEnd) {
      continuous = false;
      break;
    }
    lastEnd = seg.endOffset;
  }
  assert(continuous, '片段偏移连续无重叠无间隙');
  assertEq(lastEnd, text.length, '最后片段结束偏移等于原文长度');
}

// 测试 5：verifyOffset 校验
{
  const text = '心脏的四个腔室分别是左心房、右心房、左心室和右心室。';
  const segs = svc.split('doc1', 1, text);
  assert(svc.verifyOffset(text, segs[0]), 'verifyOffset 对正确片段返回 true');
  assert(!svc.verifyOffset('其他文本', segs[0]), 'verifyOffset 对错误文本返回 false');
}

// 测试 6：getContext 上下文提取
{
  const text = '前面的内容。' + '核心片段内容。'.repeat(5) + '后面的内容。';
  const segs = svc.split('doc1', 1, text);
  // 取中间片段
  const mid = segs[Math.floor(segs.length / 2)];
  const ctx = svc.getContext(text, mid, 10);
  assert(ctx.includes(mid.content), '上下文包含片段内容');
  assert(ctx.length <= mid.content.length + 20, '上下文长度不超过片段+前后扩展');
}

// 测试 7：片段 ID 格式
{
  const text = '测试片段 ID。';
  const segs = svc.split('my-doc', 3, text);
  assert(segs[0].id.startsWith('my-doc-r3-s0'), `片段 ID 格式正确：${segs[0].id}`);
}

// ===== KnowledgeEventBus 测试 =====
console.log('\n[KnowledgeEventBus]');

const bus = new KnowledgeEventBus();

// 测试 8：订阅与通知
{
  let received: any = null;
  const unsub = bus.subscribe((e) => { received = e; });
  bus.emit({
    type: 'created',
    documentId: 'doc1',
    revision: 1,
    segments: [],
    timestamp: 123
  });
  assert(received !== null, '订阅者收到事件');
  assertEq(received.type, 'created', '事件类型正确');
  assertEq(received.documentId, 'doc1', '事件 documentId 正确');
  unsub();
}

// 测试 9：取消订阅后不再收到
{
  let count = 0;
  const unsub = bus.subscribe(() => { count++; });
  bus.emit({ type: 'deleted', documentId: 'x', revision: 1, segments: [], timestamp: 0 });
  unsub();
  bus.emit({ type: 'deleted', documentId: 'y', revision: 1, segments: [], timestamp: 0 });
  assertEq(count, 1, '取消订阅后不再收到事件');
}

// 测试 10：监听器异常不影响其他监听器
{
  let okListenerCalled = false;
  bus.subscribe(() => { throw new Error('boom'); });
  bus.subscribe(() => { okListenerCalled = true; });
  bus.emit({ type: 'created', documentId: 'z', revision: 1, segments: [], timestamp: 0 });
  assert(okListenerCalled, '一个监听器异常不影响其他监听器');
}

// 测试 11：事件历史记录
{
  const history = bus.getHistory();
  assert(history.length >= 3, `事件历史记录保留（${history.length} 条）`);
}

// ===== 种子数据测试 =====
console.log('\n[SeedDocuments]');

// 测试 12：种子资料数量达标
{
  assert(SEED_COUNT >= 10, `种子资料数量达标（${SEED_COUNT} 篇）`);
}

// 测试 13：每篇资料都有标题、来源和正文
{
  let allValid = true;
  for (const doc of SEED_DOCUMENTS) {
    if (!doc.title || !doc.source || !doc.content || doc.content.length < 50) {
      allValid = false;
      console.error(`    资料不完整：${doc.title}`);
    }
  }
  assert(allValid, '每篇资料都有标题、来源和足够正文');
}

// 测试 14：种子资料切分后片段可定位原文
{
  let allSegmentsValid = true;
  for (const doc of SEED_DOCUMENTS) {
    const segs = svc.split('seed', 1, doc.content);
    if (segs.length === 0) {
      allSegmentsValid = false;
      console.error(`    ${doc.title} 切分为空`);
      continue;
    }
    for (const seg of segs) {
      if (!svc.verifyOffset(doc.content, seg)) {
        allSegmentsValid = false;
        console.error(`    ${doc.title} 片段 #${seg.seqIndex} 偏移校验失败`);
      }
    }
  }
  assert(allSegmentsValid, '所有种子资料的片段均可定位原文');
}

// 测试 15：种子资料来源标注
{
  const sources = new Set(SEED_DOCUMENTS.map(d => d.source.split(',')[0]));
  assert(sources.size >= 1, `种子资料来源标注清晰（${sources.size} 类来源）`);
}

// ===== 汇总 =====
console.log(`\n========== 结果：${passed} passed, ${failed} failed ==========`);
if (failed > 0) {
  process.exit(1);
}
