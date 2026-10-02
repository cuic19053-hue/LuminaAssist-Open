# 光语助手（LuminaAssist）

面向视障与高龄用户的**端云双态**多模态智能助理——用语音完成阅读、认物、看药与问答。

---

## 特性

- **视觉辅助**：拍照后 OCR / 物品识别 / 药品信息结构化播报  
- **语音驱动**：长按说话，一句话触发多步任务  
- **端云双态**：端侧低延迟（分类 / TTS）+ 后端合规代理（意图与规划）  
- **无障碍优先**：大热区、高对比、VUI 兜底（失败必有语音反馈）  
- **隐私**：API Key 经鸿蒙 HUKS 加密；图像按需临时传输  

---

## 架构一览

```
OpenHarmony App (ArkTS / ArkUI)
  UI → Agent → Vision / Speech / LLM / HttpClient
                 │
                 │ HTTP（规划等）
                 ▼
         FastAPI Backend
                 │
                 ▼
         阿里云百炼 DashScope
```

| 场景 | 路径 | 说明 |
| --- | --- | --- |
| 物品粗分类（MobileNetV2） | 端侧 | 毫秒级，可弱网/离线 |
| 视觉细描述 / TTS | 端侧直连为主 | 低延迟 |
| Agent 意图拆解与多任务规划 | 后端代理 | Prompt + Key 统一托管 |

---

## 仓库结构

```
.
├── README.md                 # 本文件
├── LuminaApp/                # 鸿蒙端侧工程（DevEco 打开此目录）
├── backend/                  # Python FastAPI 后端
└── docs/
    ├── SETUP_HARMONYOS.md     # 环境从 0 搭建
    ├── MANUAL_TEST_GUIDE.md   # 手动测试指南
    └── ux_report.md           # UX 与无障碍审计报告
```

---

## 快速开始

### 1. 后端

```powershell
cd backend
pip install -r requirements.txt
copy .env.example .env
# 编辑 .env，填入 ALIYUN_API_KEY
python main.py
# http://localhost:8000  →  curl /health
```

### 2. 端侧

1. 安装 [DevEco Studio 5.0+](https://developer.huawei.com/consumer/cn/deveco-studio/) 与 OpenHarmony 5.0（API 12）SDK  
2. `File` → `Open` → 选择 **`LuminaApp/`**（不要选仓库根目录）  
3. 复制 `LuminaApp/local.properties.template` 为 `local.properties`，填写 `sdk.dir`  
4. 配置自动签名 → 连接真机/模拟器 → Run  
5. 设置页填写后端地址（真机用电脑局域网 IP，勿用 `localhost`）

完整步骤见 [docs/SETUP_HARMONYOS.md](docs/SETUP_HARMONYOS.md)。

### 3. 技术栈

| 类别 | 技术 |
| --- | --- |
| 端侧 | OpenHarmony 5.0、ArkTS、ArkUI Stage |
| 端侧推理 | MindSpore Lite + MobileNetV2 |
| 后端 | Python 3.10+、FastAPI、Uvicorn |
| 模型服务 | DashScope（qwen-vl / qwen-plus） |

---

## 实验报告

同一套实验内容，由两位报告人各自独立撰写（结构相近、表述不同）：

| 文档 | 报告人 | 文风简述 |
| --- | --- | --- |
| [实验报告_陈默.md](docs/实验报告_陈默.md) | 陈默 | 偏正式、表格化客观记录 |
| [实验报告_林书言.md](docs/实验报告_林书言.md) | 林书言 | 偏叙事、第一人称操作感受 |

用例编号均为 E-01～E-08，覆盖健康检查、任务规划、阅读、认物、药品、问答、故障与权限兜底。

---

## 安全约定

1. 禁止硬编码 API Key；端侧走 KeyStore，后端走 `.env`（已 gitignore）  
2. 相机 / 麦克风按需申请  
3. 所有错误路径须 TTS（或振动）反馈  
4. 药品相关播报仅供辅助，不能替代医嘱  

---

## 更多文档

- [LuminaApp/README.md](LuminaApp/README.md) — 端侧工程说明  
- [backend/README.md](backend/README.md) — 后端启动与 API  
- [LuminaApp/docs/architecture.md](LuminaApp/docs/architecture.md) — 架构设计  
- [LuminaApp/docs/api_contract.md](LuminaApp/docs/api_contract.md) — Agent API 契约  
- [LuminaApp/docs/camera_permission_guide.md](LuminaApp/docs/camera_permission_guide.md) — 权限指南  

---

## License

MIT License © 2026 LuminaAssist Contributors
