# Smart Item Recognition Assistant

鸿蒙 ArkTS / ArkUI 客户端与 FastAPI 后端的最小开发起点。目前包含空首页、健康检查接口和业务目录占位。

## Agent 导航

开发前阅读 [AGENTS.md](AGENTS.md)，其中包含模块与文档地图、工作规则、协作分工和验证入口。第一阶段角色任务见 [Agent Prompts](docs/phase-1-agent-prompts.md)。

## 目录

- `app/`：可用 DevEco Studio 打开的 Stage 模型工程。
- `backend/`：FastAPI 入口及 API、配置、模型、服务和测试目录。
- `docs/requirements.md`：实验功能清单。
- `docs/api-plan.md`：待实现接口规划。

## 鸿蒙客户端

1. 在 DevEco Studio 中打开 `app/`，同步工程。
2. 工程配置沿用本机已有项目的 modelVersion 26.0.0、targetSdkVersion 26.0.0、compatibleSdkVersion 6.1.1(24)。按 IDE 提示安装对应 SDK。
3. 运行到模拟器；真机运行前，在 Signing Configs 中配置个人签名。

当前仅声明网络权限；相机功能开发时补充权限声明和运行时授权。

### 模型准备

`yolov13n.onnx` 放置于 `app/entry/src/main/resources/rawfile/models/`（被 `.gitignore` 排除，**新克隆必须手动放置**）。

- **SHA-256**：`f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b`
- **来源**：见 `docs/phase-1-model.md`
- **HAP 验证**：`unzip -l entry-default-unsigned.hap | grep models/` 应显示 `resources/rawfile/models/yolov13n.onnx`
- **ONNX Runtime OHOS**：npm 包 `@ohos/onnxruntime_ohos`，当前仅提供 arm64-v8a 原生库。详细 ABI 限制见 `AGENTS.md`「ABI / SDK 兼容性决策」。

ONNX Runtime 依赖和业务逻辑已接入，真机 arm64-v8a + SDK 26 为目标设备。

## 后端

使用 Python 3.10 或更高版本。在 `backend/` 中运行：

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.lock.txt
python -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

健康检查：http://127.0.0.1:8000/health
接口文档：http://127.0.0.1:8000/docs

真机联调时将监听地址改为 `0.0.0.0`，客户端使用开发机局域网 IP。后端当前仅提供公开健康检查，业务接口开发时统一接入鉴权。

`.env.example` 为未来配置模板；当前入口未加载该文件。密钥保持空白，鉴权实现时通过环境注入。requirements.txt 声明基础依赖范围，requirements.lock.txt 记录本机验证使用的精确版本。

## 推荐开发顺序

图像采集 → 端侧预处理与推理 → 后处理和展示 → TaskPool 与耗时对比 → RDB → 后端鉴权 → 同步队列 → 模型更新与统计。

## 本机命令行构建

在 `SmartItemRecognitionAssistant/` 运行 `./scripts/build-app.sh`，脚本使用 DevEco Studio 内置 Node、Java 和 SDK。安装路径可通过 `DEVECO_ROOT` 覆盖。未配置签名时生成 `app/entry/build/default/outputs/default/entry-default-unsigned.hap`。
