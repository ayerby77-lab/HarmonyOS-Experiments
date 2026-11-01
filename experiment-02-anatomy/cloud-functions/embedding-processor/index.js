// CFKit 云函数：embedding 生成。
//
// 环境变量（部署时配置）：
//   EMBEDDING_PROVIDER — volcengine | dashscope | openai（默认 volcengine）
//   API_KEY            — 供应商密钥
//   MODEL              — 模型名，例如 doubao-embedding-large
//   DIMENSION          — 向量维度，例如 2048

const http = require('@cfkit/runtime/http');

const providers = {
  volcengine: {
    endpoint: 'https://ark.cn-beijing.volces.com/api/v3/embeddings',
    buildBody(texts, model) {
      return { model, input: texts };
    },
    parseResp(obj) {
      return obj.data.map(d => d.embedding);
    },
  },
  dashscope: {
    endpoint: 'https://dashscope.aliyuncs.com/api/v1/services/embeddings/text-embedding/text-embedding',
    buildBody(texts, model) {
      return {
        model,
        input: { texts },
        parameters: { dimension: parseInt(process.env.DIMENSION || '1536', 10) },
      };
    },
    parseResp(obj) {
      return obj.output?.embeddings?.map(e => e.embedding) ?? [];
    },
  },
  openai: {
    endpoint: 'https://api.openai.com/v1/embeddings',
    buildBody(texts, model) {
      return { model, input: texts };
    },
    parseResp(obj) {
      return obj.data.map(d => d.embedding);
    },
  },
};

exports.handler = async function (event, context) {
  const req = event;
  const res = context.response;

  if (req.method !== 'POST') {
    res.statusCode = 405;
    res.end('method not allowed');
    return;
  }

  let body;
  try { body = JSON.parse(req.body || '{}'); }
  catch { res.statusCode = 400; res.end('invalid json'); return; }

  const texts = Array.isArray(body.texts) ? body.texts : [body.text];
  if (texts.length === 0 || texts.every(t => !t || !t.trim())) {
    res.statusCode = 400;
    res.end('text(s) is empty');
    return;
  }

  const providerName = process.env.EMBEDDING_PROVIDER || 'volcengine';
  const provider = providers[providerName];
  if (!provider) {
    res.statusCode = 500;
    res.end(`unknown provider: ${providerName}`);
    return;
  }

  const model = process.env.MODEL || body.model || 'doubao-embedding-large';

  try {
    const upstream = await fetch(provider.endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${process.env.API_KEY}`,
      },
      body: JSON.stringify(provider.buildBody(texts, model)),
    });

    const json = await upstream.json();
    if (!upstream.ok) {
      res.statusCode = 502;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ error: 'upstream_failure', detail: json }));
      return;
    }

    const vectors = provider.parseResp(json);
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({
      model,
      dimension: vectors[0]?.length ?? 0,
      count: vectors.length,
      vectors,
    }));
  } catch (err) {
    res.statusCode = 500;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ error: err?.message || String(err) }));
  }
};
