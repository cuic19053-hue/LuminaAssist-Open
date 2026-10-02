"""
光语助手 LuminaAssist 后端服务。

基于 FastAPI 实现的多模态智能助理后端，为视障人士与高龄长者服务。
提供视觉识别与 Agent 任务规划两个核心接口，统一接入阿里云百炼（OpenAI 兼容模式）。

接口清单：
- POST /api/v1/vision/analyze  视觉识别接口（图像 → 中文描述）
- POST /api/v1/agent/plan      Agent 任务规划接口（语音文本 → 结构化任务）
- GET  /health                 健康检查接口

架构层级：本文件为演示阶段的合并实现（Controller + Service），
生产环境可拆分为 routers/ services/ schemas/ 三层目录（已预留于 backend/routers、backend/services）。
"""

import os
import json
import logging

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Depends
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional
from openai import OpenAI

from database import engine
from models import Base, User
from routers.auth import router as auth_router, get_current_user_optional
from routers import agent, auth, sync, medicine

# ==================== 初始化 ====================

# 加载 .env 环境变量（API Key 等敏感信息禁止硬编码，优先使用 .env 中的配置）
load_dotenv(override=True)

# 日志配置：统一格式，便于端侧 / 运维排查
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("lumina.backend")

# FastAPI 应用初始化
app = FastAPI(title="LuminaAssist Backend", version="1.0.0")

# 初始化数据库
Base.metadata.create_all(bind=engine)

# Include routers
app.include_router(auth_router)
app.include_router(sync.router)
app.include_router(medicine.router)

# CORS 配置（开发期允许所有来源；生产环境应收敛到端侧包名白名单）
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ==================== 配置读取 ====================

# API Key 仅从环境变量读取，禁止硬编码（VUI 铁律：隐私合规）
RAW_API_KEY = os.getenv("ALIYUN_API_KEY", "").strip()
# 排除占位符模板文本（如 your_aliyun_key_here）
IS_KEY_CONFIGURED = bool(RAW_API_KEY) and "your_" not in RAW_API_KEY.lower() and "xxx" not in RAW_API_KEY.lower()
ALIYUN_API_KEY = RAW_API_KEY if IS_KEY_CONFIGURED else ""

ALIYUN_BASE_URL = os.getenv("ALIYUN_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1")
ALIYUN_VISION_MODEL = os.getenv("ALIYUN_VISION_MODEL", "qwen-vl-max")
ALIYUN_TEXT_MODEL = os.getenv("ALIYUN_TEXT_MODEL", "qwen-plus")

# 本地 Qwen2-VL 推理服务（vlm_server.py，GPU 部署）。未配置本地服务时默认关闭。
LOCAL_VLM_ENABLED = os.getenv("LOCAL_VLM_ENABLED", "0") == "1"
LOCAL_VLM_BASE_URL = os.getenv("LOCAL_VLM_BASE_URL", "http://127.0.0.1:8000/v1")
LOCAL_VLM_MODEL = os.getenv("LOCAL_VLM_MODEL", "qwen2-vl-2b-instruct")

# 启动日志：仅打印是否配置，禁止打印实际 Key 值
logger.info(f"ALIYUN_API_KEY configured: {IS_KEY_CONFIGURED}")


# ==================== Pydantic 模型 ====================

class VisionAnalyzeRequest(BaseModel):
    """视觉识别请求模型。

    Attributes:
        image_base64: 图片的 base64 编码字符串（不带 data:image/jpeg;base64, 前缀）
    """
    image_base64: str


class AgentPlanRequest(BaseModel):
    """Agent 任务规划请求模型。

    Attributes:
        text: 用户语音转写后的文本指令
    """
    text: str


class BackendTask(BaseModel):
    """后端下发的单个任务单元。

    Attributes:
        action: 任务动作（capture_image / image_classify / medicine_recognition /
                send_sms / call_ride / vision_analyze / emergency_call / read_screen）
        target: 任务目标（联系人/电话/目的地/固定标识，可空）
        content: 任务内容（如短信正文，可空）
    """
    action: str
    target: str = ""
    content: str = ""


class VisionAnalyzeResponse(BaseModel):
    """视觉识别响应模型。

    Attributes:
        tts_message: 用于 TTS 播报的中文描述
    """
    tts_message: str


class AgentPlanResponse(BaseModel):
    """Agent 任务规划响应模型。

    Attributes:
        tasks: 任务列表
        tts_message: 对用户的简短中文回应
    """
    tasks: List[BackendTask]
    tts_message: str


# ==================== 工具函数 ====================

def _parse_agent_json(content: str) -> dict:
    """解析 Agent 返回的 JSON 内容。

    优先直接 json.loads；失败时剥离 ```json ... ``` 代码块后重试。
    阿里云百炼在 response_format=json_object 下通常直接返回纯 JSON，
    此处兜底处理偶发的代码块包裹情况。

    Args:
        content: 大模型返回的原始文本

    Returns:
        dict: 解析后的字典

    Raises:
        json.JSONDecodeError: 两种方式都解析失败时抛出，由调用方兜底处理
    """
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        pass
    # 兜底：剥离 ```json ... ``` 或 ``` ... ``` 代码块后重试
    stripped = content.strip()
    if stripped.startswith("```"):
        lines = stripped.split("\n")
        # 移除首行（``` 或 ```json）
        if lines and lines[0].strip() in ("```", "```json"):
            lines = lines[1:]
        # 移除末行 ```
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        inner = "\n".join(lines).strip()
        return json.loads(inner)  # 若仍失败，抛出 JSONDecodeError 由调用方处理
    raise json.JSONDecodeError("无法解析为 JSON 且非代码块格式", content, 0)


# ==================== 接口 1: 视觉识别 ====================

def _vision_chat(model: str, base_url: str, api_key: str, prompt: str, image_base64: str, timeout: float) -> str:
    """调用 OpenAI 兼容视觉服务并返回描述文本。"""
    client = OpenAI(api_key=api_key, base_url=base_url, timeout=timeout)
    completion = client.chat.completions.create(
        model=model,
        messages=[
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}}
                ]
            }
        ],
        temperature=0.4,
        max_tokens=200
    )
    return completion.choices[0].message.content


@app.post("/api/v1/vision/analyze", response_model=VisionAnalyzeResponse)
def vision_analyze(req: VisionAnalyzeRequest) -> VisionAnalyzeResponse:
    """视觉识别接口。

    接收 base64 图片，优先调用本地 Qwen2-VL 推理服务（vlm_server.py，GPU），
    失败时自动降级阿里云百炼 Qwen-VL，返回简短中文描述供端侧 TTS 播报。
    适用于药品识别、菜单朗读、物体描述等场景。

    Args:
        req: 包含 image_base64 的请求体

    Returns:
        VisionAnalyzeResponse: 包含 tts_message 的响应

    Raises:
        HTTPException: 502 本地与云端视觉链路均不可用
    """
    prompt = "你是一位视障辅助助手，请用简短中文描述图片中的关键信息（如药品名称、说明书、菜单、物体等），不超过 50 字，直接给出描述，不要加前缀。"

    # 链路 1：本地 Qwen2-VL（无 Key、低延迟、数据不出域）
    if LOCAL_VLM_ENABLED:
        try:
            content = _vision_chat(LOCAL_VLM_MODEL, LOCAL_VLM_BASE_URL, "local", prompt, req.image_base64, timeout=3.0)
            logger.info("视觉识别走本地 Qwen2-VL")
            return VisionAnalyzeResponse(tts_message=content)
        except Exception as e:
            logger.warning("本地 Qwen2-VL 不可用，准备降级云端: %s", str(e).encode('utf-8', 'replace').decode('utf-8'))

    # 链路 2：阿里云百炼降级
    if not ALIYUN_API_KEY:
        raise HTTPException(status_code=502, detail="视觉识别服务暂不可用（本地模型未就绪且未配置云端 API Key）")
    try:
        content = _vision_chat(ALIYUN_VISION_MODEL, ALIYUN_BASE_URL, ALIYUN_API_KEY, prompt, req.image_base64, timeout=30.0)
        logger.info("视觉识别走阿里云 Qwen-VL")
        return VisionAnalyzeResponse(tts_message=content)
    except Exception as e:
        err_msg = str(e).encode('utf-8', 'replace').decode('utf-8')
        logger.error("视觉识别失败: %s", err_msg)
        raise HTTPException(status_code=502, detail="视觉识别服务暂不可用")


# ==================== 接口 2: Agent 任务规划 ====================

@app.post("/api/v1/agent/plan", response_model=AgentPlanResponse)
def agent_plan(req: AgentPlanRequest, current_user: Optional[User] = Depends(get_current_user_optional)) -> AgentPlanResponse:
    """Agent 任务规划接口。

    接收用户语音文本，调用阿里云百炼文本大模型解析意图并输出结构化任务列表。
    端侧 Agent 拿到 tasks 后分发到对应 Service 执行（发短信/打车/紧急呼叫等）。

    Args:
        req: 包含 text 的请求体

    Returns:
        AgentPlanResponse: 包含 tasks 和 tts_message 的响应；
        JSON 解析失败时兜底返回空任务列表与"我没听明白"提示（不返回 500）

    Raises:
        HTTPException: 500 服务端未配置 API Key；502 Agent 服务暂不可用
    """
    if not ALIYUN_API_KEY:
        raise HTTPException(status_code=500, detail="服务端未配置 API Key")

    user_context = ""
    if current_user and current_user.profile:
        prof = current_user.profile
        context_parts = []
        if prof.get("chronic_diseases"):
            context_parts.append(f"慢病史: {', '.join(prof['chronic_diseases'])}")
        if prof.get("allergies"):
            context_parts.append(f"过敏史: {', '.join(prof['allergies'])}")
        if prof.get("medication_habits"):
            context_parts.append(f"用药习惯: {prof['medication_habits']}")
        if context_parts:
            user_context = f" 当前用户的健康档案与偏好如下：{'；'.join(context_parts)}。"

    system_prompt = f"""你是光语助手的任务规划器。根据用户语音，输出严格的 JSON（不要包裹在 ```json 中）。
格式：{{"tasks":[{{"action":"...","target":"...","content":"..."}}],"tts_message":"..."}}{user_context}
action 可选：capture_image / image_classify / medicine_recognition / send_sms / call_ride / vision_analyze / emergency_call / read_screen
- capture_image: target 固定 "camera"，端侧取帧缓存（不直接返回 TTS，需配合后续 image_classify / vision_analyze）
- image_classify: target 固定 "camera"，端侧 MobileNetV2 优先 + 云端 Qwen-VL 兜底（用户问"这是什么/识别一下/看看/这是什么物品"等识别意图时下发，通常前置 capture_image）
- medicine_recognition: target 固定 "camera"，药品识别（用户提到"这是什么药/这药怎么吃/识别药品/看看说明书"等用药意图时下发，端侧会自动取帧，无需前置 capture_image）
- send_sms: 仅当用户明确要发短信/发消息时使用。target 为联系人姓名或电话，content 为短信正文（用户未给正文时 content 可为空）
- call_ride: target 为目的地或固定 "default"
- vision_analyze: target 固定 "camera"，纯云端 Qwen-VL 视觉分析（用于需要详细描述/读书/读药品说明等复杂场景）
- emergency_call: 电话/呼叫意图。target 为联系人姓名、电话或 "120"/"110"/"119"。用户说"给X打电话/打出X的电话/呼叫X/拨打X"时，target 只填联系人姓名（如"妈妈""张三"），不要填整句；content 通常为空
- read_screen: target 固定 "screen"
【打电话 vs 发短信 — 必须严格区分，禁止混淆】
- 出现"打电话/打出…电话/呼叫/拨打"且未提及"短信/发短信/发消息/发微信" → 必须用 emergency_call，禁止用 send_sms；target 只填联系人姓名或号码
- 仅当用户明确要发短信/发消息（如"发短信""给X发短信说…"）时才用 send_sms；content 为短信正文
- 正例（emergency_call）："给妈妈打电话"→target="妈妈"；"给张三打电话"→target="张三"；"打出妈妈的电话"→target="妈妈"；"打电话给妈妈"→target="妈妈"；"拨打妈妈的电话"→target="妈妈"；"呼叫120"→target="120"
- 反例（禁止判为 send_sms）："给妈妈打电话"、"给张三打电话" 绝不是发短信
- 正例（send_sms）："给妈妈发短信说我到家了"→target="妈妈", content="我到家了"
tts_message 为对用户的简短中文回应（不超过 20 字）。
策略提示：对于"这是什么/识别一下/看看"等物品识别意图，优先下发 [{{"action":"capture_image","target":"camera","content":""}},{{"action":"image_classify","target":"camera","content":""}}] 组合任务，由端侧先取帧再分类。
若无法理解意图，返回 {{"tasks":[],"tts_message":"我没听明白，请再说一遍"}}。"""

    try:
        client = OpenAI(api_key=ALIYUN_API_KEY, base_url=ALIYUN_BASE_URL)
        completion = client.chat.completions.create(
            model=ALIYUN_TEXT_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": req.text}
            ],
            temperature=0.3,
            max_tokens=500,
            response_format={"type": "json_object"}
        )
        content = completion.choices[0].message.content

        # JSON 解析：失败时兜底返回，不抛 500（符合 VUI 铁律：禁止静默失败，但也不可惊吓用户）
        try:
            data = _parse_agent_json(content)
        except json.JSONDecodeError:
            logger.warning(f"Agent 任务规划 JSON 解析失败，兜底返回。原始内容: {content}")
            return AgentPlanResponse(tasks=[], tts_message="我没听明白，请再说一遍")

        # 校验 tasks 是 list，tts_message 是 str
        tasks_raw = data.get("tasks", [])
        if not isinstance(tasks_raw, list):
            tasks_raw = []
        tts_msg = data.get("tts_message", "好的")
        if not isinstance(tts_msg, str):
            tts_msg = "好的"

        return AgentPlanResponse(tasks=tasks_raw, tts_message=tts_msg)
    except HTTPException:
        raise
    except Exception as e:
        err_msg = str(e).encode('utf-8', 'replace').decode('utf-8')
        logger.error("Agent 任务规划失败: %s", err_msg)
        raise HTTPException(status_code=502, detail="Agent 服务暂不可用")


# ==================== 健康检查接口 ====================

@app.get("/health")
def health_check() -> dict:
    """健康检查接口。

    用于运维监控与端侧启动时的连通性检测。
    返回 api_key_configured 布尔值便于端侧提前提示用户配置状态。

    Returns:
        dict: {"status": "ok", "api_key_configured": bool}
        （禁止返回实际 API Key 值）
    """
    return {"status": "ok", "api_key_configured": bool(ALIYUN_API_KEY)}


# ==================== 华为应用市场上架合规网页 ====================

@app.get("/privacy", response_class=HTMLResponse)
def privacy_page() -> str:
    """公开隐私保护政策页面（供 AppGallery Connect 上架及外部审核查验使用）。"""
    return """<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>光语助手 - 隐私政策与个人信息保护指引</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", sans-serif; line-height: 1.7; color: #333; max-width: 800px; margin: 0 auto; padding: 24px; background: #fafbfc; }
        .card { background: #fff; padding: 32px; border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; }
        h1 { color: #0f766e; font-size: 24px; border-bottom: 2px solid #0f766e; padding-bottom: 12px; margin-top: 0; }
        h2 { color: #111827; font-size: 18px; margin-top: 24px; }
        p, li { font-size: 15px; color: #4b5563; }
        .highlight { background: #ecfdf5; border-left: 4px solid #10b981; padding: 12px 16px; border-radius: 4px; margin: 16px 0; }
        .footer { text-align: center; margin-top: 32px; font-size: 13px; color: #9ca3af; }
    </style>
</head>
<body>
<div class="card">
    <h1>光语助手（LuminaAssist）隐私保护政策</h1>
    <p>更新日期：2026年10月01日 &nbsp;|&nbsp; 生效日期：2026年10月01日</p>
    
    <div class="highlight">
        <strong>引言：</strong>光语助手致力于为视障人士及银发长者提供无障碍生活辅助。我们高度重视用户的个人信息安全与隐私权，严格遵循《中华人民共和国个人信息保护法》及《网络安全法》等法律法规。
    </div>

    <h2>一、 我们如何收集和使用您的个人信息</h2>
    <p>我们严格坚持“最小必要”与“场景触发”原则，绝不在后台静默收集您的个人信息：</p>
    <ul>
        <li><strong>麦克风录音权限：</strong>仅在您主动按下语音按键或发起语音指令时调用，用于语音识别（ASR）与意图分析。识别完成后即时关闭。</li>
        <li><strong>相机拍摄权限：</strong>仅在您主动发起药品包装、生活物品或文档朗读时调用，用于捕捉实时单帧图像。照片仅用于实时 OCR 与视觉推理，云端不持久化留存。</li>
        <li><strong>本地敏感数据脱敏：</strong>系统在端侧自动检测并掩码身份证、银行卡等连续数字，防止敏感信息上传。</li>
        <li><strong>网络访问：</strong>用于与云端多模态大模型进行安全通信（HTTPS 全程加密）。</li>
    </ul>

    <h2>二、 我们如何共享、转让和公开披露您的信息</h2>
    <p>我们不会向任何第三方公司、组织和个人出售或共享您的个人信息。所调用的 AI 算法服务均符合国家生成式人工智能合规规范，所有数据传输采用金融级 TLS 加密。</p>

    <h2>三、 您的权利与撤回授权</h2>
    <p>您有权随时管理您的个人信息：</p>
    <ul>
        <li>在系统“设置”中随时关闭相机、麦克风等权限；</li>
        <li>在应用“设置”页面底部点击“撤回隐私政策授权”，撤回后本应用将清除本地缓存并退出服务。</li>
    </ul>

    <h2>四、 免责声明与健康提示</h2>
    <p>本软件提供的药品识别与文字朗读由人工智能多模态模型生成，仅供生活便利辅助参考，<strong>不构成任何处方指导、用药建议或医疗诊断</strong>。用药前请仔细核对药品实体说明书或遵医嘱。</p>

    <h2>五、 联系我们与不良信息举报</h2>
    <p>如对本隐私政策有任何疑问、建议或投诉举报，请联系我们：<br>
    联系邮箱：<strong>feedback@lumina.assist</strong><br>
    处理时效：我们将在收到您的反馈后 24 小时内完成核实处理。</p>
</div>
<div class="footer">
    <p>光语助手 LuminaAssist 团队 &nbsp;|&nbsp; 开发者保留所有权利</p>
</div>
</body>
</html>"""


@app.get("/terms", response_class=HTMLResponse)
def terms_page() -> str:
    """公开用户服务协议页面。"""
    return """<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>光语助手 - 用户服务协议与免责声明</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", sans-serif; line-height: 1.7; color: #333; max-width: 800px; margin: 0 auto; padding: 24px; background: #fafbfc; }
        .card { background: #fff; padding: 32px; border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; }
        h1 { color: #0f766e; font-size: 24px; border-bottom: 2px solid #0f766e; padding-bottom: 12px; margin-top: 0; }
        h2 { color: #111827; font-size: 18px; margin-top: 24px; }
        p, li { font-size: 15px; color: #4b5563; }
        .alert { background: #fef3c7; border-left: 4px solid #f59e0b; padding: 12px 16px; border-radius: 4px; margin: 16px 0; }
        .footer { text-align: center; margin-top: 32px; font-size: 13px; color: #9ca3af; }
    </style>
</head>
<body>
<div class="card">
    <h1>光语助手（LuminaAssist）用户服务协议</h1>
    <p>更新日期：2026年10月01日</p>
    
    <h2>1. 服务概述</h2>
    <p>光语助手是一款基于 HarmonyOS 与多模态 AI 架构的无障碍智能辅助应用，为视障群体和高龄长者提供全语音交互、药品识别、物品定位及文档朗读等辅助功能。</p>

    <div class="alert">
        <strong>特别警示：</strong>药品识别与阅读功能由人工智能算法生成，受光照、磨损等环境限制可能存在识别误差，仅供日常生活参考，不能代替专业医师或药师指导。
    </div>

    <h2>2. 用户行为规范</h2>
    <p>用户在使用本服务时，须遵守国家相关法律法规，不得利用本服务制作、传播违规信息或进行任何危害网络安全的行为。</p>

    <h2>3. 知识产权与算法声明</h2>
    <p>光语助手的整体设计、软件代码、智能体编排架构受知识产权法律保护。服务依托符合国家《生成式人工智能服务管理暂行办法》的合格基座模型。</p>

    <h2>4. 协议修改与终止</h2>
    <p>我们可能会根据业务调整或监管要求更新本协议，修改后的协议将在应用内及本页面公布。用户有权随时终止使用并撤回授权。</p>
</div>
<div class="footer">
    <p>光语助手 LuminaAssist 团队</p>
</div>
</body>
</html>"""



# ==================== 启动入口 ====================

if __name__ == "__main__":
    import uvicorn
    logger.info("已注册路由: %s", [r.path for r in app.routes])
    uvicorn.run(app, host="0.0.0.0", port=8000)
