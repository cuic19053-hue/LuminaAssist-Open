"""pytest 全局夹具。

提供 FastAPI TestClient 与 Mock OpenAI 客户端，避免真实调用阿里云百炼产生费用。
"""
from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

# 将 backend 根目录加入 sys.path，便于 import main
BACKEND_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_ROOT))


@pytest.fixture()
def client() -> TestClient:
    """返回 FastAPI TestClient。

    使用 TestClient 可在不启动真实 HTTP 服务的情况下直接调用路由。
    """
    from main import app

    return TestClient(app)


@pytest.fixture()
def fake_openai(monkeypatch: pytest.MonkeyPatch):
    """注入一个伪造的 OpenAI 客户端，避免真实网络调用。

    使用方式：
        def test_xxx(client, fake_openai):
            fake_openai.set_chat_response({"content": "你好"})
            resp = client.post("/api/v1/agent/plan", json={"text": "你好"})
            ...

    Returns:
        FakeOpenAI: 可配置响应的伪造客户端实例
    """
    fake = FakeOpenAI()

    def _factory(*args: Any, **kwargs: Any) -> FakeOpenAI:
        return fake

    # main.py 内使用 `from openai import OpenAI`，此处替换其引用
    import main as main_module

    monkeypatch.setattr(main_module, "OpenAI", _factory)
    return fake


class FakeChatCompletion:
    """伪造的单次 chat completion 结果。"""

    def __init__(self, content: str) -> None:
        self.choices = [type("Choice", (), {"message": type("Msg", (), {"content": content})()})()]


class FakeChat:
    """伪造的 chat 接口。"""

    def __init__(self, owner: "FakeOpenAI") -> None:
        self._owner = owner

    @property
    def completions(self) -> "FakeChat":
        return self

    def create(self, *args: Any, **kwargs: Any) -> FakeChatCompletion:
        self._owner.create_call_count += 1
        if "messages" in kwargs:
            self._owner.last_messages = kwargs["messages"]
        if self._owner._raise_on_create:
            raise self._owner._raise_on_create
        return FakeChatCompletion(self._owner._next_response)


class FakeOpenAI:
    """可编程的 OpenAI 客户端替身。

    Attributes:
        create_call_count: chat.completions.create 累计调用次数
    """

    def __init__(self) -> None:
        self._next_response: str = ""
        self._raise_on_create: Exception | None = None
        self.create_call_count: int = 0
        self.last_messages: list = []
        self.chat = FakeChat(self)

    def set_chat_response(self, content: str) -> None:
        """设置下一次 chat.completions.create 返回的内容。"""
        self._next_response = content

    def set_raise(self, exc: Exception) -> None:
        """让下一次 create 抛出指定异常。"""
        self._raise_on_create = exc

    def reset(self) -> None:
        """重置状态。"""
        self._next_response = ""
        self._raise_on_create = None
        self.create_call_count = 0
