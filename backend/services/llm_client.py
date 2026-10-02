"""LLM 客户端封装（服务层内部使用）。

封装 OpenAI 兼容 SDK 的调用，供 VisionService / AgentService 复用。
统一处理：
- 认证失败（401/403）
- 限流（429）
- 服务端异常（5xx）
- 超时
- 其他网络异常
"""

import time
import logging
from typing import List, Dict, Any, Optional

from openai import OpenAI
from openai import APIError, APIConnectionError, APITimeoutError, AuthenticationError, RateLimitError

logger = logging.getLogger("lumina.backend.llm")


class LLMClient:
    """OpenAI 兼容协议客户端封装。

    Attributes:
        api_key: 阿里云百炼 API Key
        base_url: 兼容模式接口基础地址
    """

    def __init__(self, api_key: str, base_url: str):
        self.api_key = api_key
        self.base_url = base_url
        self._client: Optional[OpenAI] = None

    @property
    def client(self) -> OpenAI:
        if self._client is None:
            self._client = OpenAI(api_key=self.api_key, base_url=self.base_url, timeout=60.0, max_retries=2)
        return self._client

    def chat(self, model: str, messages: List[Dict[str, Any]],
             temperature: float = 0.3, max_tokens: int = 500,
             response_format: Optional[Dict[str, str]] = None,
             timeout: float = 60.0) -> str:
        """发起一次 Chat Completion 调用。

        Args:
            model: 模型名
            messages: 消息列表（与 OpenAI 兼容格式）
            temperature: 采样温度
            max_tokens: 最大输出 token 数
            response_format: 响应格式（如 {"type": "json_object"}）

        Returns:
            str: 模型返回的文本内容

        Raises:
            ValueError: API Key 未配置
            RuntimeError: 服务异常，附带中文描述
        """
        if not self.api_key:
            raise ValueError("服务端未配置 API Key")

        try:
            kwargs: Dict[str, Any] = {
                "model": model,
                "messages": messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
            }
            if response_format:
                kwargs["response_format"] = response_format
            kwargs["timeout"] = timeout

            completion = self.client.chat.completions.create(**kwargs)
            content = completion.choices[0].message.content or ""
            logger.info("LLM chat success model=%s len=%d", model, len(content))
            return content
        except AuthenticationError as e:
            logger.error("LLM auth failed: %s", e)
            raise RuntimeError("API 鉴权失败，请检查 API Key") from e
        except RateLimitError as e:
            logger.error("LLM rate limited: %s", e)
            raise RuntimeError("请求过于频繁，请稍后再试") from e
        except APITimeoutError as e:
            logger.error("LLM timeout: %s", e)
            raise RuntimeError("大模型调用超时，请重试") from e
        except APIConnectionError as e:
            logger.error("LLM connection error: %s", e)
            raise RuntimeError("网络连接失败，请稍后再试") from e
        except APIError as e:
            logger.error("LLM API error: %s", e)
            raise RuntimeError("大模型服务暂不可用，请稍后再试") from e
        except Exception as e:
            logger.error("LLM unexpected error: %s", e)
            raise RuntimeError("大模型调用失败，请稍后再试") from e

    def chat_stream(self, model: str, messages: List[Dict[str, Any]],
                    temperature: float = 0.3, max_tokens: int = 500,
                    response_format: Optional[Dict[str, str]] = None,
                    timeout: float = 60.0):
        """发起一次流式 Chat Completion 调用。

        Yields:
            str: 增量生成的文本片段
        """
        if not self.api_key:
            raise ValueError("服务端未配置 API Key")
        try:
            kwargs: Dict[str, Any] = {
                "model": model,
                "messages": messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
                "stream": True,
            }
            if response_format:
                kwargs["response_format"] = response_format
            kwargs["timeout"] = timeout

            stream = self.client.chat.completions.create(**kwargs)
            for chunk in stream:
                if chunk.choices and chunk.choices[0].delta and chunk.choices[0].delta.content:
                    yield chunk.choices[0].delta.content
        except Exception as e:
            logger.error("LLM stream error: %s", e)
            raise RuntimeError("大模型流式调用失败，请稍后再试") from e
