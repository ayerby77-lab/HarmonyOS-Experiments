// CFKit 云函数：问答模型转发。
//
// 职责：
//   1. 接收客户端的 prompt + model 参数。
//   2. 根据 MODEL_PROVIDER 环境变量选择模型供应商。
//   3. 用云端密钥（环境变量）调用供应商 API。
//   4. 把供应商的流式响应翻译成 SSE 事件吐给客户端。
//
// 为什么用云函数：
//   验收要求「密钥保存在云端」。客户端不持有任何 API key。
//   同时云函数可以统一 prompt 模板、日志、限流和审计。
//
// 环境变量（部署时在 CFKit 控制台配置）：
//   MODEL_PROVIDER   — doubao | dashscope | openai （默认 doubao）
//   API_KEY          — 供应商密钥
//   MODEL_ENDPOINT   — 可选，自定义 endpoint
//   DEFAULT_MODEL    — 可选，默认模型名
//   ALLOWED_MODELS   — 可选，逗号分隔的允许模型白名单

const http = require('@cfkit/runtime/http');

// 模型供应商适配层。不同供应商的 API 格式不同，这里做薄封装。
const providers = {
  doubao: {
    endpoint: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    transform(body) {
      const messages = [
        { role: 'user', content: body.prompt },
      ];
      return {
        model: body.model || process.env.DEFAULT_MODEL || 'doubao-pro-32k',
        messages,
        stream: true,
      };
    },
    apiKey() { return process.env.API_KEY; },
    streamParser(rawLine) {
      // Volcengine Ark 的 SSE 格式：data: {...}
      if (!rawLine.startsWith('data:')) return null;
      const payload = rawLine.slice(5).trim();
      if (payload === '[DONE]') return { done: true };
      try {
        const obj = JSON.parse(payload);
        const delta = obj.choices?.[0]?.delta?.content ?? '';
        return { token: delta };
      } catch {
        return null;
      }
    },
  },
  dashscope: {
    endpoint: 'https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation',
    transform(body) {
      return {
        model: body.model || process.env.DEFAULT_MODEL || 'qwen-turbo',
        input: { prompt: body.prompt },
        parameters: { result_format: 'message_stream' },
      };
    },
    apiKey() { return process.env.API_KEY; },
    streamParser(rawLine) {
      if (!rawLine.startsWith('data:')) return null;
      try {
        const obj = JSON.parse(rawLine.slice(5).trim());
        const delta = obj.output?.choices?.[0]?.message?.content ?? '';
        return { token: delta };
      } catch {
        return null;
      }
    },
  },
  openai: {
    endpoint: 'https://api.openai.com/v1/chat/completions',
    transform(body) {
      return {
        model: body.model || process.env.DEFAULT_MODEL || 'gpt-4o-mini',
        messages: [{ role: 'user', content: body.prompt }],
        stream: true,
      };
    },
    apiKey() { return process.env.API_KEY; },
    streamParser(rawLine) {
      if (!rawLine.startsWith('data:')) return null;
      const payload = rawLine.slice(5).trim();
      if (payload === '[DONE]') return { done: true };
      try {
        const obj = JSON.parse(payload);
        const delta = obj.choices?.[0]?.delta?.content ?? '';
        return { token: delta };
      } catch {
        return null;
      }
    },
  },
};

function sse(res, event, data) {
  res.write(`event:${event}\n`);
  res.write(`data:${typeof data === 'string' ? data : JSON.stringify(data)}\n\n`);
}

exports.handler = async function (event, context) {
  const req = event; // CFKit 请求对象
  const res = context.response;

  if (req.method !== 'POST') {
    res.statusCode = 405;
    res.end('method not allowed');
    return;
  }

  let body;
  try { body = JSON.parse(req.body || '{}'); }
  catch {
    res.statusCode = 400;
    res.end('invalid json');
    return;
  }

  if (!body.prompt || !body.prompt.trim()) {
    res.statusCode = 400;
    res.end('prompt is empty');
    return;
  }

  // 模型白名单校验
  const allowed = (process.env.ALLOWED_MODELS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (allowed.length > 0 && body.model && !allowed.includes(body.model)) {
    res.statusCode = 400;
    res.end('model not allowed');
    return;
  }

  const providerName = process.env.MODEL_PROVIDER || 'doubao';
  const provider = providers[providerName];
  if (!provider) {
    res.statusCode = 500;
    res.end(`unknown provider: ${providerName}`);
    return;
  }

  if (!provider.apiKey()) {
    res.statusCode = 500;
    res.end('API key not configured on cloud');
    return;
  }

  // 设置 SSE 响应头
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Access-Control-Allow-Origin', '*');

  try {
    const upstream = await fetch(provider.endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${provider.apiKey()}`,
      },
      body: JSON.stringify(provider.transform(body)),
    });

    if (!upstream.ok) {
      sse(res, 'error', {
        code: mapProviderError(upstream.status),
        message: `upstream HTTP ${upstream.status}`,
      });
      res.end();
      return;
    }

    if (!upstream.body) {
      sse(res, 'error', { code: 'model_error', message: 'no body from upstream' });
      res.end();
      return;
    }

    const reader = upstream.body.getReader();
    const decoder = new TextDecoder('utf-8');
    let buffer = '';

    sse(res, 'message_start', '');

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let sep;
      while ((sep = buffer.indexOf('\n')) !== -1) {
        const line = buffer.substring(0, sep);
        buffer = buffer.substring(sep + 1);
        if (!line.trim()) continue;
        const parsed = provider.streamParser(line);
        if (parsed?.token) {
          sse(res, 'token', parsed.token);
        }
        if (parsed?.done) break;
      }
    }

    sse(res, 'message_end', '');
    res.end();
  } catch (err) {
    sse(res, 'error', {
      code: 'model_error',
      message: err?.message || String(err),
    });
    res.end();
  }
};

function mapProviderError(status) {
  if (status === 401 || status === 403) return 'auth_failure';
  if (status === 429) return 'rate_limit';
  if (status >= 500) return 'model_error';
  return 'unknown';
}
