from sqlalchemy import Column, Integer, String, JSON, ForeignKey, BigInteger
from sqlalchemy.orm import relationship
from database import Base

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    device_id = Column(String, unique=True, index=True, nullable=False)
    profile = Column(JSON, default=dict) # Stores {"chronic_diseases": [], "allergies": [], "medication_habits": ""}
    
    chat_logs = relationship("ChatLog", back_populates="owner")
    action_logs = relationship("ActionLog", back_populates="owner")

class ChatLog(Base):
    __tablename__ = "chat_logs"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"))
    local_id = Column(String, index=True) # UUID from device
    role = Column(String) # 'user' or 'assistant'
    content = Column(String)
    timestamp = Column(BigInteger)
    
    owner = relationship("User", back_populates="chat_logs")

class ActionLog(Base):
    __tablename__ = "action_logs"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"))
    local_id = Column(String, index=True)
    action_type = Column(String) # e.g., 'ocr_scan'
    action_detail = Column(String)
    timestamp = Column(BigInteger)
    
    owner = relationship("User", back_populates="action_logs")
