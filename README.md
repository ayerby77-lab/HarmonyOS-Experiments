# 鸿蒙课程实验合集

本仓库用于课程实验检查与评优答辩，目前收录实验一至实验三的代码、项目文档和实验要求。实验四待补充。

| 实验 | 目录 | 内容 |
| --- | --- | --- |
| 一：音乐播放 App | [experiment-01-music](experiment-01-music/) | 音乐播放器源码、资源与项目文档 |
| 二：人体解剖浏览器 | [experiment-02-anatomy](experiment-02-anatomy/) | 鸿蒙客户端、人体模型与 Web 资源、云函数及文档 |
| 三：智能物品识别助手 | [experiment-03-recognition](experiment-03-recognition/) | 鸿蒙客户端、FastAPI 后端、测试与设计文档 |

## 阅读和运行

各实验的 `assignment/` 目录保存老师的实验要求 Word 文档。运行方法、依赖和验证记录请参阅各目录下的 README.md 以及 doc/ 或 docs/。

实验一、二使用 DevEco Studio 打开对应实验目录；实验三打开 `experiment-03-recognition/app/`，后端位于其 `backend/`。

实验三的 YOLOv13n ONNX 模型按原项目规则未纳入 Git，运行识别前需依照其模型文档配置模型文件。构建缓存、依赖目录、本机 SDK 配置与私密环境配置均按忽略规则处理。

## 整理来源

- 实验一：ayerby77-lab/MusicApp，提交 `9d5f9b196fe827fa74905ef0f485c47bef9e6da7`。
- 实验二：ayerby77-lab/AnatomyLearning，提交 `96474940eefc665ff085a2f7f664a7ed6e4b31c4`。
- 实验三：ayerby77-lab/SmartItemRecognitionAssistant，提交 `ebb624563d3d79e84b54652202515f57435e7946`。

本次整理保留源项目的代码和已有文档。各项目文档记录的完成状态及历史测试结果需结合实际运行核实；本次仅验证文件整理与远端同步，未重新执行三个实验的运行验收。
