# 光语助手 鸿蒙端侧应用

> LuminaAssist HarmonyOS Client —— OpenHarmony 5.0 + ArkUI Stage 模型 + 端云双态架构

---

## ⚠️ 重要说明

> **必须使用 DevEco Studio 5.0+ 导入 `LuminaApp/` 目录进行开发和编译调试。**
>
> 当前仓库环境**无法直接编译鸿蒙应用**。完整工程文件已就位（`build-profile.json5` / `oh-package.json5` / `AppScope/` / `entry/` / `module.json5`），DevEco Studio 导入后即可识别为标准 OpenHarmony 5.0 工程。
>
> **首次配置 SDK 路径**：将 [`LuminaApp/local.properties.template`](file:///d:/c4.ai.huawei/LuminaApp/local.properties.template) 复制为 `LuminaApp/local.properties`，填入本机 SDK 路径（已被 .gitignore 忽略，禁止提交）。
>
> **完整装机指南**：见仓库根目录 [`docs/SETUP_HARMONYOS.md`](file:///d:/c4.ai.huawei/docs/SETUP_HARMONYOS.md)。

---

## 一、工程概览

| 项 | 值 |
| --- | --- |
| 平台 | OpenHarmony 5.0 (API 12) |
| 架构 | Stage 模型 + 声明式 ArkUI |
| 包名 | `lumi.na.app` |
| 主入口 | `EntryAbility` → `pages/Index` |
| 智能体 | 端云双态（端侧 ArkTS + 后端 Python FastAPI 代理） |

---

## 二、目录结构

```
LuminaApp/
├── AppScope/                          # 应用级配置
│   ├── app.json5
│   └── resources/
│       └── base/element/string.json
├── build-profile.json5                # 工程构建配置
├── code-linter.json5
├── hvigorfile.ts
├── oh-package.json5
├── local.properties.template          # SDK 路径模板（需 cp 为 local.properties）
├── entry/                             # 主模块
│   ├── build-profile.json5
│   ├── hvigorfile.ts
│   ├── oh-package.json5
│   ├── obfuscation-rules.txt
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/
│       │   │   └── EntryAbility.ets   # 主入口
│       │   ├── pages/
│       │   │   └── Index.ets          # 主页
│       │   ├── agent/                 # 智能体（核心）
│       │   │   ├── Agent.ets
│       │   │   ├── IntentRouter.ets
│       │   │   ├── TaskPlanner.ets
│       │   │   └── types.ets
│       │   ├── services/              # 端侧服务
│       │   │   ├── LLMClient.ets
│       │   │   ├── SpeechService.ets
│       │   │   ├── VisionService.ets
│       │   │   ├── HttpClient.ets
│       │   │   ├── ASRService.ets
│       │   │   ├── LocalImageClassifier.ets
│       │   │   ├── LocalOCREngine.ets
│       │   │   └── LocalVisionLLMEngine.ets
│       │   ├── components/            # UI 组件
│       │   │   ├── BigButton.ets
│       │   │   ├── StatusBanner.ets
│       │   │   └── ConversationBubble.ets
│       │   └── utils/                 # 工具
│       │       ├── AccessibilityUtils.ets
│       │       ├── Logger.ets
│       │       ├── PermissionUtil.ets
│       │       └── KeyStoreUtil.ets
│       ├── module.json5               # 权限 + Ability 清单
│       └── resources/
│           ├── base/
│           │   ├── element/{color,string}.json
│           │   └── profile/main_pages.json
│           ├── en_US/element/string.json
│           └── zh_CN/element/string.json
├── docs/
│   ├── architecture.md
│   ├── api_contract.md
│   └── camera_permission_guide.md
└── README.md                          # 本文档
```

---

## 三、环境要求

| 项 | 要求 |
| --- | --- |
| IDE | DevEco Studio 5.0+ |
| OpenHarmony SDK | API 12（OpenHarmony 5.0） |
| 目标设备 | OpenHarmony 5.0 真机 / 模拟器 |
| 网络 | 后端代理模式需要后端可达；端侧直连模式需要 LLM 可达 |

> 详细装机步骤见 [`docs/SETUP_HARMONYOS.md`](file:///d:/c4.ai.huawei/docs/SETUP_HARMONYOS.md)

---

## 四、导入与运行

1. 打开 **DevEco Studio 5.0+**
2. `File` → `Open` → 选择 `LuminaApp/` 目录（**不是仓库根目录**）
3. 等待 IDE 完成 **ohpm + hvigor sync**（首次约 5-10 分钟）
4. 配置 SDK 路径：复制 `LuminaApp/local.properties.template` 为 `LuminaApp/local.properties` 并填入本机 SDK 路径
5. 配置签名：`File` → `Project Structure` → `Project` → `Signing Configs` → 勾选 `Automatically generate signature`
6. 连接 OpenHarmony 5.0 真机或启动模拟器
7. 点击 **Run** 部署 HAP

---

## 五、首次运行

1. **（端云双态-后端路径）** 启动后端：
   ```powershell
   cd ../backend
   pip install -r requirements.txt
   copy .env.example .env
   # 编辑 .env 填入 ALIYUN_API_KEY
   python main.py
   # 后端启动在 http://localhost:8000
   ```
2. 启动应用 → 自动初始化 TTS 引擎
3. 录入 LLM API Key（设置页），或确认后端已配置（设置页输入后端地址）
4. 点击中央大按钮开始语音对话
5. 视障用户可全程使用语音 + 触觉反馈

---

## 六、无障碍设计

- **大热区**：主按钮 ≥ 120vp 高度，命中区完整
- **高对比度**：黑底 + 亮黄主按钮（#FFD400），满足 WCAG AAA
- **VUI 优先**：TTS 主通道 + 振动降级
- **错误兜底**：所有异常必须 TTS 反馈

---

## 七、相关文档

- [架构设计](./docs/architecture.md)
- [Agent API 契约](./docs/api_contract.md)
- [相机/麦克风权限指南](./docs/camera_permission_guide.md)
- [鸿蒙环境搭建指南](../docs/SETUP_HARMONYOS.md)
- [后端启动指南](../backend/README.md)
