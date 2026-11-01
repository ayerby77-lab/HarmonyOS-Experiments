# 人体解剖学习

独立 HarmonyOS Stage / ArkTS 基础工程，包名 `com.example.anatomylearning`。

## 打开与构建

在 DevEco Studio 中打开本目录 `AnatomyLearning`。沿用本机已有 SDK 配置：兼容 API 12，目标 SDK 26.0.0；工具路径由 `local.properties` 指定，可按本机安装位置调整。模拟器部署时在 DevEco Studio 中配置所需签名。

命令行构建：`bash scripts/build.sh`，产物输出至 `dist/`。脚本使用本机 DevEco Studio，并在临时目录编译。

## 当前范围

已建立应用启动、首页导航、8 个业务/辅助页面、共用占位组件和知识数据类型。问答页可输入问题；发送按钮在服务接入后启用。当前业务页面均为占位，尚未接入 3D 模型、数据库、模型服务、ArkAF 或课程资料。

## 目录

- `entry/src/main/ets/pages/`：页面
- `entry/src/main/ets/components/`：共用组件
- `entry/src/main/ets/model/`：数据类型
- `entry/src/main/ets/entryability/`：应用生命周期
- `entry/src/main/resources/`：页面注册、字符串和图标
- `doc/后续任务.md`：实施顺序与验收标准

后续按需增加 `store/`（RDB）、`service/`（检索与云端调用）、`bridge/`（Web 通信），避免空实现混入真实业务。
