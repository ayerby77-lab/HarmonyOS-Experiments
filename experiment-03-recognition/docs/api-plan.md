# 接口规划

当前仅实现 `GET /health`。下列业务路径为开发建议，待实现时确定请求和响应字段。记录字段、标识与幂等语义以 [`docs/phase-1-data-contract.md`](phase-1-data-contract.md) 为准。

## 健康检查

| 方法 | 路径 | 状态 | 响应 |
| --- | --- | --- | --- |
| GET | `/health` | 已实现 | `200 {"status":"ok"}` |

健康检查保持公开、无鉴权；`/docs` 仅在开发环境暴露。

## 业务接口

| 方法 | 路径 | 用途 | 状态 |
| --- | --- | --- | --- |
| POST | `/api/v1/auth/token` | 设备标识与密钥换取令牌 | 待实现 |
| POST | `/api/v1/auth/refresh` | 刷新令牌 | 待实现 |
| GET | `/api/v1/models/latest` | 模型版本与下载信息 | 待实现 |
| GET | `/api/v1/models/{version}/download` | 模型下载 | 待实现 |
| POST | `/api/v1/records/batch` | 按 `recordId` 幂等批量上传 | 待实现 |
| GET | `/api/v1/records` | 时间、类别筛选和分页 | 待实现 |
| GET | `/api/v1/records/{recordId}` | 单条记录详情 | 待实现 |
| GET | `/api/v1/statistics` | 识别统计 | 待实现 |

除 `/health` 外均需 Bearer 鉴权；鉴权失败返回 401。第一阶段不实现上述业务接口。

## 记录上传规划

### 请求

`POST /api/v1/records/batch`

```json
{
  "schemaVersion": 1,
  "records": [
    {
      "schemaVersion": 1,
      "recordId": "5d0f6b9e-2c1a-4e8b-9f7d-3a6c2b8e4f10",
      "requestId": "req-1792630992345-003",
      "imageId": "img-1792630992345-01",
      "capturedAtMs": 1792630992345,
      "recognizedAtMs": 1792631000781,
      "savedAtMs": 1792631004000,
      "editedAtMs": null,
      "imageWidth": 810,
      "imageHeight": 1080,
      "isMirrored": false,
      "imageOrigin": "gallery",
      "model": {
        "modelId": "yolov13n-coco-640-opset18",
        "sha256": "f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b"
      },
      "options": {
        "confidenceThreshold": 0.25,
        "iouThreshold": 0.7,
        "maxDetections": 300,
        "executionMode": "taskpool"
      },
      "timing": {
        "preprocessMs": 18.4,
        "inferenceMs": 126.7,
        "postprocessMs": 9.2,
        "totalMs": 154.3,
        "coldStart": false,
        "modelLoadMs": 0
      },
      "rawDetectionCount": 0,
      "edited": false,
      "detections": [],
      "counts": []
    }
  ]
}
```

说明：

- 单批建议最多 50 条；请求体只含 JSON，不含缩略图/原图二进制。
- `recordId` 由客户端离线生成，是幂等键；服务端以“认证设备 + `recordId`”唯一约束。
- `detections` 包含全部原始框，包括 `deleted=true` 的项；`counts` 仅作校验，服务端按明细重算。
- 不接受本地字段：缩略图/原图路径、同步状态、重试计数、绝对路径和设备密钥。
- 完整字段语义见数据契约第 3 节。

### 响应

```json
{
  "results": [
    {
      "recordId": "5d0f6b9e-2c1a-4e8b-9f7d-3a6c2b8e4f10",
      "status": "created",
      "serverRevision": "1"
    }
  ]
}
```

- `status`：`created` / `duplicate` / `conflict` / `invalid`。
- 幂等行为：相同 `recordId` 且规范化载荷相同返回 `duplicate`；载荷不同返回冲突，不覆盖已有记录。
- 部分成功：逐条返回结果；客户端只把 `created`/`duplicate` 标记为已上传，其余保留重试或转为永久失败。

## 记录查询规划

`GET /api/v1/records`

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `fromMs` / `toMs` | integer | 按 `recognizedAtMs` 筛选，Unix 毫秒，闭区间 |
| `classId` | integer | 按最终类别筛选；仅匹配 `deleted=false` 的检测项 |
| `page` / `pageSize` | integer | 页码从 1 开始；`pageSize` 建议 ≤ 100 |
| `cursor` | string | 后续可选；与页码分页二选一 |

排序固定为 `recognizedAtMs DESC, recordId DESC`。列表返回记录摘要（含最终 `counts`）；详情接口返回完整 `detections`。

## 统计规划

`GET /api/v1/statistics`

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `fromMs` / `toMs` | integer | 统计时间范围，按 `recognizedAtMs` |
| `groupBy` | string | `class` / `day` / `model`，默认 `class` |

统计只使用最终类别且排除 `deleted=true` 的检测项；空结果记录计入识别次数，但不产生类别计数。

## 错误响应规划

统一结构：

```json
{
  "code": "RECORD_CONFLICT",
  "message": "recordId 已存在且载荷不同",
  "detail": "recordId=..."
}
```

建议状态码：

| 状态码 | 场景 |
| --- | --- |
| 400 | 请求格式或字段值非法 |
| 401 | 缺少、过期或无效令牌 |
| 409 | `recordId` 冲突或载荷不一致 |
| 422 | `schemaVersion` 不支持或语义校验失败 |
| 500 | 服务端异常 |

业务接口接入 JWT 鉴权；鉴权失败返回 401。记录、队列与数据库设计在对应业务阶段补充，第一阶段保持离线识别可独立运行。
