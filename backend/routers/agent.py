"""Agent 任务规划路由。"""

import logging
from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

from schemas.agent import AgentPlanRequest, AgentPlanResponse
from services.agent_service import AgentService

logger = logging.getLogger("lumina.backend.agent.router")

router = APIRouter(prefix="/api/v1/agent", tags=["agent"])

_agent_service: AgentService | None = None


def init_router(service: AgentService) -> None:
    """注入 service 依赖（由 main.py 在应用启动时调用）。"""
    global _agent_service
    _agent_service = service


def _get_service() -> AgentService:
    if _agent_service is None:
        raise HTTPException(status_code=500, detail="服务未初始化")
    return _agent_service


@router.post("/plan")
def agent_plan(req: AgentPlanRequest):
    """Agent 任务规划接口 (SSE 流式输出)。

    接收用户语音文本与历史记录，调用文本大模型解析意图。
    通过 SSE 返回 tts_chunk 和 tasks。
    """
    try:
        service = _get_service()
        return StreamingResponse(
            service.plan_stream(req.text, req.history),
            media_type="text/event-stream"
        )
    except ValueError as e:
        raise HTTPException(status_code=500, detail=str(e)) from e
    except RuntimeError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    except Exception as e:
        logger.error("agent_plan unexpected error: %s", e)
        raise HTTPException(status_code=500, detail="服务器内部错误") from e
