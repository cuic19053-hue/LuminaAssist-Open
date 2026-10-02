"""Agent 任务规划服务。

封装意图识别与任务规划 Prompt，输出结构化 BackendTask 列表。
"""

import json
import logging
from typing import List

from services.llm_client import LLMClient
from services.base import parse_agent_json
from schemas.agent import AgentPlanResponse, BackendTask
from utils.privacy import PrivacyFilter

logger = logging.getLogger("lumina.backend.agent")


AGENT_SYSTEM_PROMPT = """你是光语助手的任务规划器。根据用户语音，输出严格的 JSON（不要包裹在 ```json 中）。
格式：{"tasks":[{"action":"...","target":"...","content":"..."}],"tts_message":"..."}
action 可选：capture_image / image_classify / send_sms / call_ride / vision_analyze / emergency_call / read_screen / medicine_recognition
- capture_image: target 固定 "camera"，端侧取帧缓存
- image_classify: target 固定 "camera"，端侧 MobileNetV2 优先 + 云端 Qwen-VL 兜底
- send_sms: 仅当用户明确要发短信/发消息时使用。target 为联系人姓名或电话，content 为短信正文（用户未给正文时 content 可为空）
- call_ride: target 固定 "default"
- vision_analyze: target 固定 "camera"，纯云端 Qwen-VL 视觉分析
- emergency_call: 电话/呼叫意图。target 为联系人姓名、电话或 "120"/"110"/"119"。用户说"给X打电话/打出X的电话/呼叫X/拨打X"时，target 只填联系人姓名（如"妈妈""张三"），不要填整句；content 通常为空
- read_screen: target 固定 "screen"
- medicine_recognition: target 固定 "camera"，药品专用识别（药盒/说明书/药片 → 药品名+用法用量+禁忌）
【打电话 vs 发短信 — 必须严格区分，禁止混淆】
- 出现"打电话/打出…电话/呼叫/拨打"且未提及"短信/发短信/发消息/发微信" → 必须用 emergency_call，禁止用 send_sms；target 只填联系人姓名或号码
- 仅当用户明确要发短信/发消息（如"发短信""给X发短信说…"）时才用 send_sms；content 为短信正文
- 正例（emergency_call）："给妈妈打电话"→target="妈妈"；"给张三打电话"→target="张三"；"打出妈妈的电话"→target="妈妈"；"打电话给妈妈"→target="妈妈"；"拨打妈妈的电话"→target="妈妈"；"呼叫120"→target="120"
- 反例（禁止判为 send_sms）："给妈妈打电话"、"给张三打电话" 绝不是发短信
- 正例（send_sms）："给妈妈发短信说我到家了"→target="妈妈", content="我到家了"
策略提示：
- 对于"这是什么/识别一下/看看"等物品识别意图，优先下发 [capture_image, image_classify] 组合任务。
- 对于"药怎么吃/药品/药盒/说明书/用量/服用"等药品相关意图，优先下发 [capture_image, medicine_recognition] 组合任务。
tts_message 为对用户的简短中文回应（不超过 20 字）。
若无法理解意图，返回 {"tasks":[],"tts_message":"我没听明白，请再说一遍"}。"""


FALLBACK_RESPONSE = AgentPlanResponse(tasks=[], tts_message="我没听明白，请再说一遍")


class AgentService:
    """Agent 任务规划服务。

    Attributes:
        llm_client: LLM 客户端
        text_model: 文本大模型名称
    """

    def __init__(self, llm_client: LLMClient, text_model: str):
        self.llm_client = llm_client
        self.text_model = text_model
        
    def _build_messages(self, text: str, history: List[dict] | None = None) -> List[dict]:
        messages = [{"role": "system", "content": AGENT_SYSTEM_PROMPT}]
        if history:
            for item in history:
                role = item.get("role", "user")
                if role not in ("user", "assistant", "system"):
                    role = "user"
                # 对历史记录脱敏
                clean_text = PrivacyFilter.mask_text(str(item.get("text", "")))
                messages.append({"role": role, "content": clean_text})
        # 对当前输入脱敏
        clean_current_text = PrivacyFilter.mask_text(text)
        messages.append({"role": "user", "content": clean_current_text})
        return messages

    def plan(self, text: str, history: List[dict] | None = None) -> AgentPlanResponse:
        """根据用户文本生成任务规划。

        Args:
            text: 用户语音转写文本
            history: 历史记录

        Returns:
            AgentPlanResponse: 结构化任务列表 + TTS 回应
            （JSON 解析失败时兜底返回空列表 + "我没听明白"，不抛异常）
        """
        messages = self._build_messages(text, history)
        content = self.llm_client.chat(
            model=self.text_model,
            messages=messages,
            temperature=0.3,
            max_tokens=500,
            response_format={"type": "json_object"},
        )

        try:
            data = parse_agent_json(content)
        except json.JSONDecodeError:
            logger.warning("Agent plan JSON parse failed, fallback. raw=%s", content)
            return FALLBACK_RESPONSE

        tasks_raw = data.get("tasks", [])
        if not isinstance(tasks_raw, list):
            tasks_raw = []
        tts_msg = data.get("tts_message", "好的")
        if not isinstance(tts_msg, str):
            tts_msg = "好的"

        tasks: List[BackendTask] = []
        for t in tasks_raw:
            if not isinstance(t, dict):
                continue
            try:
                tasks.append(BackendTask(
                    action=str(t.get("action", "")),
                    target=str(t.get("target", "")),
                    content=str(t.get("content", "")),
                ))
            except Exception as e:
                logger.warning("Skip invalid task %s: %s", t, e)
                continue

        return AgentPlanResponse(tasks=tasks, tts_message=tts_msg)

    def plan_stream(self, text: str, history: List[dict] | None = None):
        """流式规划，拦截 tts_message 并产生 SSE 事件。
        
        Yields:
            str: SSE 格式事件串
        """
        messages = self._build_messages(text, history)
        stream = self.llm_client.chat_stream(
            model=self.text_model,
            messages=messages,
            temperature=0.3,
            max_tokens=500,
            response_format={"type": "json_object"}
        )
        
        full_json = ""
        in_tts = False
        tts_buffer = ""
        tts_sent = ""
        
        # 标点符号用于切分句子
        punctuation = ("。", "？", "！", "，", ".", "?", "!", ",")
        
        for chunk in stream:
            full_json += chunk
            
            if not in_tts:
                # 检测是否进入 tts_message 字段
                if '"tts_message":' in full_json.replace(" ", ""):
                    # 找到 tts_message 的值起始引号
                    parts = full_json.split('"tts_message"')
                    if len(parts) > 1:
                        val_part = parts[1].strip()
                        if val_part.startswith(':'):
                            val_part = val_part[1:].strip()
                            if val_part.startswith('"'):
                                in_tts = True
                                tts_buffer = val_part[1:]
                                
            if in_tts:
                if '"' in chunk: # tts_message 结束
                    # 最后一个分号可能带有引号，直接清理
                    pass 
                
                tts_buffer += chunk
                # 寻找标点断句
                for i, char in enumerate(tts_buffer):
                    if char in punctuation:
                        sentence = tts_buffer[:i+1].replace('"', '')
                        if sentence.strip() and sentence != tts_sent:
                            yield f"event: tts_chunk\ndata: {sentence}\n\n"
                            tts_sent = sentence
                        tts_buffer = tts_buffer[i+1:]
                        break
        
        # 兜底：如果缓冲中还有剩余句子
        if tts_buffer.replace('"', '').strip():
            sentence = tts_buffer.replace('"', '').strip()
            yield f"event: tts_chunk\ndata: {sentence}\n\n"

        # 生成完成，解析 full JSON 获取 tasks
        try:
            data = parse_agent_json(full_json)
        except json.JSONDecodeError:
            data = {}
        
        tasks_raw = data.get("tasks", [])
        if not isinstance(tasks_raw, list):
            tasks_raw = []
        
        tasks: List[dict] = []
        for t in tasks_raw:
            if isinstance(t, dict):
                tasks.append({
                    "action": str(t.get("action", "")),
                    "target": str(t.get("target", "")),
                    "content": str(t.get("content", ""))
                })
        
        yield f"event: tasks\ndata: {json.dumps(tasks)}\n\n"
