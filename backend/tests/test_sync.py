import pytest
from fastapi.testclient import TestClient
from main import app
from database import Base, engine, get_db
from models import ChatLog, ActionLog
from sqlalchemy.orm import sessionmaker
from sqlalchemy import StaticPool, create_engine
import time
import uuid

# Use in-memory SQLite for testing
SQLALCHEMY_DATABASE_URL = "sqlite:///:memory:"
engine_test = create_engine(
    SQLALCHEMY_DATABASE_URL,
    connect_args={"check_same_thread": False},
    poolclass=StaticPool,
)
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine_test)

Base.metadata.create_all(bind=engine_test)

def override_get_db():
    try:
        db = TestingSessionLocal()
        yield db
    finally:
        db.close()

app.dependency_overrides[get_db] = override_get_db
client = TestClient(app)

def test_sync_push_append_only():
    # 1. Login to get token
    response = client.post("/api/v1/auth/login", json={"device_id": "test_device_sync"})
    assert response.status_code == 200
    token = response.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # 2. Push 2 Chat logs and 1 Action log
    ts = int(time.time() * 1000)
    chat_id_1 = str(uuid.uuid4())
    chat_id_2 = str(uuid.uuid4())
    action_id_1 = str(uuid.uuid4())

    payload = {
        "chat_logs": [
            {"local_id": chat_id_1, "role": "user", "content": "hello", "timestamp": ts},
            {"local_id": chat_id_2, "role": "assistant", "content": "hi there", "timestamp": ts + 1000}
        ],
        "action_logs": [
            {"local_id": action_id_1, "action_type": "vision_classify", "action_detail": "It's an apple", "timestamp": ts + 2000}
        ]
    }

    push_resp = client.post("/api/v1/sync/push", json=payload, headers=headers)
    assert push_resp.status_code == 200
    res_data = push_resp.json()
    assert res_data["success"] is True
    assert res_data["synced_chat_count"] == 2
    assert res_data["synced_action_count"] == 1

    # 3. Test Idempotency (Pushing the exact same logs again should return 0 synced)
    push_resp_2 = client.post("/api/v1/sync/push", json=payload, headers=headers)
    assert push_resp_2.status_code == 200
    res_data_2 = push_resp_2.json()
    assert res_data_2["synced_chat_count"] == 0
    assert res_data_2["synced_action_count"] == 0
