"""Pydantic schema 层。

集中管理所有请求/响应模型，供 routers 和 services 共用。
"""

from .vision import VisionAnalyzeRequest, VisionAnalyzeResponse
from .agent import (
    AgentPlanRequest,
    AgentPlanResponse,
    BackendTask,
)

__all__ = [
    "VisionAnalyzeRequest",
    "VisionAnalyzeResponse",
    "AgentPlanRequest",
    "AgentPlanResponse",
    "BackendTask",
]
