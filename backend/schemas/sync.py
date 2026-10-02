from pydantic import BaseModel
from typing import List, Optional

class ChatLogItem(BaseModel):
    local_id: str
    role: str
    content: str
    timestamp: int

class ActionLogItem(BaseModel):
    local_id: str
    action_type: str
    action_detail: str
    timestamp: int

class SyncPushRequest(BaseModel):
    chat_logs: List[ChatLogItem] = []
    action_logs: List[ActionLogItem] = []

class SyncPushResponse(BaseModel):
    success: bool
    synced_chat_count: int
    synced_action_count: int
