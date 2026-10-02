"""服务层基类与通用工具。"""

import json
import logging

logger = logging.getLogger("lumina.backend.service")


def parse_agent_json(content: str) -> dict:
    """解析 Agent 返回的 JSON 内容。

    优先直接 json.loads；失败时剥离 ```json ... ``` 代码块后重试。
    阿里云百炼在 response_format=json_object 下通常直接返回纯 JSON，
    此处兜底处理偶发的代码块包裹情况。

    Args:
        content: 大模型返回的原始文本

    Returns:
        dict: 解析后的字典

    Raises:
        json.JSONDecodeError: 两种方式都解析失败时抛出
    """
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        pass
    stripped = content.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if lines and lines[0].strip() in ("```", "```json"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        inner = "\n".join(lines).strip()
        return json.loads(inner)
    raise json.JSONDecodeError("无法解析为 JSON 且非代码块格式", content, 0)
