# 光语助手 后端服务

> LuminaAssist Backend —— Python FastAPI 实现的多模态智能助理后端

---

## 一、职责

为光语助手**端云双态架构**的"后端代理路径"提供：
1. **Agent 意图拆解**：接收用户语音文本 → 输出结构化任务列表
2. **视觉识别代理**：端侧可直连云端，但本接口保留作为合规路径
3. **统一 API Key 管理**：所有 LLM 调用 Key 集中托管在 `.env`
4. **Prompt 管理**：意图拆解 System Prompt 由后端持有，端侧不写 Prompt

---

## 二、环境要求

| 项 | 要求 |
|---|---|
| Python | 3.10+ |
| 包管理 | pip / uv / poetry 任选 |
| 操作系统 | Windows / macOS / Linux 全平台 |

---

## 三、快速启动

### 步骤 1：安装依赖

```powershell
# 方式 A：pip
cd backend
pip install -r requirements.txt

# 方式 B：uv（推荐，速度快 10x）
uv venv
uv pip install -r requirements.txt
```

### 步骤 2：配置环境变量

```powershell
# 复制模板为实际配置文件
copy .env.example .env   # Windows
cp .env.example .env     # macOS/Linux

# 编辑 .env 填入你的阿里云百炼 API Key
# ALIYUN_API_KEY=sk-xxxxxxxxxxxxxxxx
```

> ⚠️ **API Key 获取**：登录阿里云百炼控制台 <https://bailian.console.aliyun.com/> → API-KEY 管理 → 创建我的 API-KEY

### 步骤 3：启动服务

```powershell
python main.py
# 或
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

启动成功标志：
```
2026-07-21 22:00:00,000 [INFO] lumina.backend: ALIYUN_API_KEY configured: True
2026-07-21 22:00:00,001 [INFO] lumina.backend: 已注册路由: ['/openapi.json', '/docs', '/docs/oauth2-redirect', '/redoc', '/health', '/api/v1/vision/analyze', '/api/v1/agent/plan']
INFO:     Uvicorn running on http://0.0.0.0:8000
```

### 步骤 4：验证服务

```powershell
# 健康检查
curl http://localhost:8000/health
# {"status":"ok","api_key_configured":true}

# API 文档（Swagger UI）
浏览器打开 http://localhost:8000/docs
```

---

## 四、API 接口

### 1. 健康检查

```http
GET /health
```

**响应**：
```json
{
  "status": "ok",
  "api_key_configured": true
}
```

### 2. 视觉识别（端云代理路径备选）

```http
POST /api/v1/vision/analyze
Content-Type: application/json

{
  "image_base64": "iVBORw0KGgoAAAANSUhEUgAA..."
}
```

**响应**：
```json
{
  "tts_message": "图片中是一盒阿莫西林胶囊，规格 0.25g×24 片，应在医生指导下使用。"
}
```

### 3. Agent 任务规划（端云双态-后端路径核心接口）

```http
POST /api/v1/agent/plan
Content-Type: application/json

{
  "text": "帮我打一辆车回家"
}
```

**响应**：
```json
{
  "tasks": [
    {"action": "call_ride", "target": "default", "content": ""}
  ],
  "tts_message": "好的，正在为您预约专车。"
}
```

完整 action 清单见后端 `system_prompt`（`main.py` 内的 Agent 接口定义）。

---

## 五、与端侧联调

### 端侧设置项

1. 打开 LuminaApp → 设置页
2. **后端地址**填入 `http://<你电脑IP>:8000`（**不要用 localhost**，真机访问不到主机）
   - 真机调试：电脑和手机连同一 WiFi，IP 形如 `192.168.1.100`
   - 模拟器：填 `10.0.2.2`（Android 模拟器访问宿主机）或 `127.0.0.1`（本地模拟器）
3. 启动后端 → 启动 App → 测试 `/api/v1/agent/plan` 路径

### 端侧 LLM Key（端侧直连路径）

如果只走端侧直连，不启后端也行：
1. 设置页 → 录入 DashScope API Key → 经鸿蒙 KeyStore 加密存储
2. 视觉识别等低延迟场景直接走端侧 LLMClient

---

## 六、项目结构

```
backend/
├── main.py                   # FastAPI 入口（routers/services/Schemas 三层汇聚点）
├── requirements.txt          # Python 依赖
├── .env.example              # 环境变量模板（提交到 git）
├── .env                      # 实际环境变量（已被 .gitignore 忽略）
├── routers/                  # 路由层（参数校验 + 调用 service + 返回响应）
│   ├── __init__.py
│   ├── vision.py             # /api/v1/vision/analyze
│   ├── agent.py              # /api/v1/agent/plan
│   └── health.py             # /health
├── services/                 # 业务服务层（LLM 调用、Prompt 管理、结果解析）
│   ├── __init__.py
│   ├── llm_client.py         # DashScope OpenAI 兼容客户端
│   ├── vision_service.py     # 视觉识别服务
│   └── agent_service.py      # Agent 意图拆解服务
└── schemas/                  # 数据模型层（请求/响应 Pydantic 模型）
    ├── __init__.py
    ├── vision.py
    └── agent.py
```

> 当前 main.py 内部直接定义了 schemas（Pydantic BaseModel），已预留 routers/services/schemas 三层目录，后续可拆分。

---

## 七、常见问题

### Q1：启动报 `ModuleNotFoundError: No module named 'openai'`
A：依赖未装齐。执行 `pip install -r requirements.txt`。

### Q2：`uvicorn: command not found`
A：未装 uvicorn。`pip install "uvicorn[standard]"`。

### Q3：`ALIYUN_API_KEY configured: False`
A：`.env` 没配或 Key 错误。检查 `backend/.env` 文件内容（注意无 BOM、无引号、无空格）。

### Q4：端侧 App 报"网络连接失败"
A：检查 ① 后端是否启动 ② 端侧填的后端地址是否正确 ③ 真机调试不要用 `localhost`，要用电脑 IP。

### Q5：后端响应慢
A：DashScope qwen-vl-max 视觉识别约 3-8 秒，qwen-plus 文本约 1-3 秒。属正常范围。可在 `main.py` 调小 `max_tokens` 加速。

---

## 八、相关文档

- [根 README.md](../README.md) - 项目总览
- [docs/SETUP_HARMONYOS.md](../docs/SETUP_HARMONYOS.md) - 鸿蒙端侧环境搭建
- [LuminaApp/docs/architecture.md](../LuminaApp/docs/architecture.md) - 端云双态架构设计
- [LuminaApp/docs/api_contract.md](../LuminaApp/docs/api_contract.md) - 端云 API 契约
