"""Agent 任务规划相关 Pydantic 模型。"""

from typing import List
from pydantic import BaseModel


class BackendTask(BaseModel):
    """后端下发的单个任务单元。

    Attributes:
        action: 任务动作（capture_image / image_classify / send_sms / call_ride / vision_analyze / emergency_call / read_screen）
        target: 任务目标（联系人/电话/固定标识，可空）
        content: 任务内容（如短信正文，可空）
    """
    action: str
    target: str = ""
    content: str = ""


class AgentPlanRequest(BaseModel):
    """Agent 任务规划请求模型。

    Attributes:
        text: 用户语音转写后的文本指令
        session_id: 会话标识，用于多轮对话（可选）
        history: 历史对话列表，格式如 [{"role": "user", "text": "..."}]（可选）
    """
    text: str
    session_id: str | None = None
    history: List[dict] | None = None


class AgentPlanResponse(BaseModel):
    """Agent 任务规划响应模型。

    Attributes:
        tasks: 任务列表
        tts_message: 对用户的简短中文回应
    """
    tasks: List[BackendTask]
    tts_message: str
