import os
import json
from fastapi import APIRouter
from pydantic import BaseModel
from services.chroma_service import search_medicine_in_db
from services.llm_client import LLMClient
from services.base import parse_agent_json

router = APIRouter(prefix="/api/v1/medicine", tags=["medicine"])

class MedicineSearchRequest(BaseModel):
    query: str

class MedicineKbEntry(BaseModel):
    name: str
    category: str
    usage: str
    fatalWarning: str

@router.post("/search", response_model=MedicineKbEntry)
def search_medicine(req: MedicineSearchRequest):
    """
    Cloud RAG Vector Search + LLM Generation endpoint.
    """
    q = req.query
    match = search_medicine_in_db(q)
    
    # Init LLM client
    api_key = os.getenv("ALIYUN_API_KEY", "")
    base_url = os.getenv("ALIYUN_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1")
    text_model = os.getenv("ALIYUN_TEXT_MODEL", "qwen-plus")
    
    has_key = bool(api_key) and "your_" not in api_key.lower() and "xxx" not in api_key.lower()

    if match and has_key:
        llm = LLMClient(api_key=api_key, base_url=base_url)
        system_prompt = f"""你是一个专门为高龄老人和视障人士服务的智能医生。
用户输入了药品查询：{q}
我们在知识库中检索到了最匹配的药品：
名称：{match['name']}
分类：{match['category']}
用法：{match['usage']}
禁忌：{match['fatalWarning']}

请根据以上知识库内容，结合用户的具体提问，生成一段通俗易懂、口语化、有温度的解释。
请严格输出 JSON 格式（不要包裹在 ```json 中）：
{{
    "name": "{match['name']}",
    "category": "{match['category']}",
    "usage": "结合用户提问生成的口语化用法说明",
    "fatalWarning": "结合知识库生成的严重禁忌强调"
}}"""
        try:
            resp = llm.chat(
                model=text_model,
                messages=[{"role": "system", "content": system_prompt}],
                temperature=0.3
            )
            parsed = parse_agent_json(resp)
            if parsed and "usage" in parsed and "fatalWarning" in parsed:
                return MedicineKbEntry(
                    name=f"{match['name']} (大模型润色)",
                    category=match['category'],
                    usage=parsed["usage"],
                    fatalWarning=parsed["fatalWarning"]
                )
        except Exception:
            pass # fallback to exact match below
    
    if match:
        return MedicineKbEntry(
            name=f"{match['name']} (云端向量检索)",
            category=match['category'],
            usage=match['usage'],
            fatalWarning=match['fatalWarning']
        )
    
    # Generic fallback if no match found
    if has_key:
        llm = LLMClient(api_key=api_key, base_url=base_url)
        system_prompt = f"""你是一个专门为高龄老人和视障人士服务的智能医生。
用户查询了药品：{q}，但在我们的核心安全知识库中未找到记录。
请根据你的医学常识，给出一个简短的建议，提醒老人去正规医院或遵医嘱。绝对不要凭空推荐陌生药品。
请严格输出 JSON 格式（不要包裹在 ```json 中）：
{{
    "name": "{q} (大模型智能建议)",
    "category": "未知/未收录药品",
    "usage": "你的口语化建议...",
    "fatalWarning": "安全提示（如不要乱吃药等）..."
}}"""
        try:
            resp = llm.chat(
                model=text_model,
                messages=[{"role": "system", "content": system_prompt}],
                temperature=0.3
            )
            parsed = parse_agent_json(resp)
            if parsed:
                return MedicineKbEntry(
                    name=parsed.get("name", f"{q} (大模型智能建议)"),
                    category=parsed.get("category", "未知药品"),
                    usage=parsed.get("usage", "请遵医嘱。"),
                    fatalWarning=parsed.get("fatalWarning", "不确定药效时绝对不要乱吃。")
                )
        except Exception:
            pass
            
    return MedicineKbEntry(
        name=f"{q} (云端基础建议)",
        category="未知药品",
        usage="系统建议：请严格遵照医生嘱咐服用。",
        fatalWarning="如服药后有任何不适，请立刻停药并就医。"
    )
