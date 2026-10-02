from pydantic import BaseModel, Field
from typing import Optional, Dict, Any

class Token(BaseModel):
    access_token: str
    token_type: str

class TokenData(BaseModel):
    device_id: Optional[str] = None
    user_id: Optional[int] = None

class DeviceLogin(BaseModel):
    device_id: str
    signature: Optional[str] = None # Optional biometric signature for verification

class UserProfile(BaseModel):
    chronic_diseases: list[str] = Field(default_factory=list, description="慢病史")
    allergies: list[str] = Field(default_factory=list, description="过敏史")
    medication_habits: str = Field(default="", description="用药习惯与作息时间")
    
class UserResponse(BaseModel):
    id: int
    device_id: str
    profile: UserProfile

    class Config:
        from_attributes = True
