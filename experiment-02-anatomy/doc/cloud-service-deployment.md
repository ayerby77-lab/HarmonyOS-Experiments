# 云端模型服务部署说明

本文档描述 AnatomyLearning 课程知识问答模块所依赖的云端服务。所有 API 密钥**仅存于云端**，客户端不持有任何敏感凭据。

## 目录结构

```
cloud-functions/
├── model-forwarder/       # 问答模型转发（SSE 流式）
│   ├── index.js
│   └── package.json
└── embedding-processor/   # embedding 生成（可选）
    ├── index.js
    └── package.json
```

## 模型供应商

云函数内置三种供应商适配，通过环境变量 `MODEL_PROVIDER` / `EMBEDDING_PROVIDER` 选择：

| 供应商 | 推荐问答模型 | 推荐 embedding 模型 | 备注 |
|--------|-------------|---------------------|------|
| 火山引擎 Volcengine Ark | doubao-pro-32k / doubao-pro-128k | doubao-embedding-large | 国内访问稳定；方舟平台 |
| 阿里云 DashScope | qwen-plus / qwen-turbo | text-embedding-v2 | 国内访问稳定 |
| OpenAI | gpt-4o-mini / gpt-4o | text-embedding-3-small | 需代理或海外部署 |

> 当前客户端默认使用 `TestEmbeddingService` 和 `TestCloudModelService`（全部离线替身）。
> 生产环境只需把 `ServiceContainer({ useCloud: true, cloudFunctionUrl: '...' })` 打开即可。

## CFKit 云函数部署步骤

### 前置条件

- 已开通华为云账号和 CFKit（云函数服务）
- 已在本地安装华为云 CLI 或使用 DevEco Studio 云函数插件

### 步骤 1：创建云函数

在 CFKit 控制台创建两个 Node.js 云函数（运行时 Node.js 18+）：
- `model-forwarder`
- `embedding-processor`（可选）

### 步骤 2：上传代码

每个云函数：
```bash
cd cloud-functions/model-forwarder
# 方式 A：压缩上传
tar -czf model-forwarder.zip index.js package.json
# 在 CFKit 控制台选择「上传代码包」

# 方式 B：CLI 部署（示例）
cfkit function deploy --name model-forwarder --runtime nodejs18 --code ./
```

### 步骤 3：配置环境变量

在 CFKit 函数的「环境变量」中设置：

**model-forwarder：**

| 变量 | 示例值 | 说明 |
|------|--------|------|
| MODEL_PROVIDER | doubao | doubao / dashscope / openai |
| API_KEY | xxxxxxxx | 供应商密钥 |
| DEFAULT_MODEL | doubao-pro-32k | 可选，覆盖默认模型 |
| ALLOWED_MODELS | doubao-pro-32k,doubao-pro-128k | 可选，模型白名单 |

**embedding-processor：**

| 变量 | 示例值 | 说明 |
|------|--------|------|
| EMBEDDING_PROVIDER | volcengine | volcengine / dashscope / openai |
| API_KEY | xxxxxxxx | 供应商密钥 |
| MODEL | doubao-embedding-large | 模型名 |
| DIMENSION | 2048 | 向量维度 |

### 步骤 4：获取 Function URL

在 CFKit 控制台的「触发器」中创建 HTTP 触发器，得到一个公开 HTTPS URL，形如：

```
https://xxx.cfkit.cloud.huawei.com/model-forwarder/v1/invoke
```

把这个 URL 写回客户端代码（`ServiceContainer` 构造参数）：

```typescript
const container = new ServiceContainer({
  useCloud: true,
  cloudFunctionUrl: 'https://xxx.cfkit.cloud.huawei.com/model-forwarder/v1/invoke',
  model: 'doubao-pro-32k',
});
```

### 步骤 5：HarmonyOS 网络权限

在 `entry/src/main/module.json5` 中声明：

```json5
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" },
  { "name": "ohos.permission.ACCESS_NETWORK_STATE" }
]
```

## 客户端 ↔ 云函数协议

### 请求（model-forwarder）

```http
POST /model-forwarder
Content-Type: application/json
Accept: text/event-stream

{
  "model": "doubao-pro-32k",   // 可选，覆盖默认
  "prompt": "<拼装好的 prompt>",
  "stream": true
}
```

### 响应（SSE）

```
event:message_start
data:

event:token
data:关于心脏的

event:token
data: 结构，

event:citation
data:{"documentId":"doc-heart-01","segmentId":"seg-heart-01","excerpt":"心脏是..."}

event:message_end
data:
```

### 错误事件

```
event:error
data:{"code":"rate_limit","message":"upstream HTTP 429"}
```

错误码与客户端 `ServiceError` 枚举一致：`auth_failure` / `rate_limit` / `model_error` / `invalid_argument`。

## 开关与替身机制

生产 / 开发环境切换只需一个构造参数：

```typescript
// 开发环境：全离线替身
const dev = new ServiceContainer({ useCloud: false });

// 生产环境：走云函数
const prod = new ServiceContainer({
  useCloud: true,
  cloudFunctionUrl: 'https://...',
  model: 'doubao-pro-32k',
});
```

任何时候 `useCloud=true` 但网络不可达，`CloudModelProxy` 会抛 `ServiceError.OFFLINE`，
UI 层按 `mapErrorToState()` 映射为 `QueryState.offline` 并提示用户。

## 版本安全

`IndexSyncManager` 为每个文档维护单调递增的 `generation` 计数器。

1. Agent C 调用 `handleDocumentChanged(docId, revision, segments)` 时，Manager 分配 `generation++`。
2. embedding 任务完成后再次检查：`generation` 是否仍是当前文档最新？如果期间又收到更新 → 丢弃结果。
3. 这是第一道防线；`MemoryVectorStore.upsert` 还有第二道 `documentRevision` 检查，进一步保险。

资料删除时调用 `handleDocumentDeleted(docId)`，立即清除向量并让进行中的旧任务自动被判为过期。

## 常见问题

**Q：云函数返回 SSE 但客户端收不到？**
A：检查 CFKit HTTP 触发器是否开启了「流式响应」开关；部分平台默认关闭。

**Q：embedding 向量维度必须与 TestEmbeddingService 一致吗？**
A：不必须。只要每个查询内的向量维度一致即可。替换为真实 embedding 后，
`TestEmbeddingService.defaultDimension = 256` 会自动由真实实现覆盖。

**Q：能同时支持多个模型吗？**
A：可以。在 `ALLOWED_MODELS` 白名单中列出，并在客户端 `ChatTurn.model` 中指定。
当前页面未暴露模型选择器；如需让用户选择，给 KnowledgeQA 加一个下拉框即可。
