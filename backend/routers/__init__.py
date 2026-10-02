"""路由层。

集中注册所有 API 路由，由 main.py 的 FastAPI 应用挂载。
每个路由模块仅做参数校验、调用 service、返回响应，不包含业务逻辑。
"""

from .vision import router as vision_router
from .agent import router as agent_router
from .health import router as health_router

__all__ = ["vision_router", "agent_router", "health_router"]
