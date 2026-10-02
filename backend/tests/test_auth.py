import pytest
from fastapi.testclient import TestClient
from main import app
from database import Base, engine, get_db
from sqlalchemy.orm import sessionmaker
from sqlalchemy import StaticPool, create_engine

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

def test_login_and_get_profile():
    # 1. Login with a new device_id
    response = client.post("/api/v1/auth/login", json={
        "device_id": "test_device_123"
    })
    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    token = data["access_token"]

    # 2. Get profile (should be empty lists)
    headers = {"Authorization": f"Bearer {token}"}
    resp2 = client.get("/api/v1/auth/profile", headers=headers)
    assert resp2.status_code == 200
    profile_data = resp2.json()["profile"]
    assert profile_data["chronic_diseases"] == []

    # 3. Update profile
    update_data = {
        "chronic_diseases": ["高血压"],
        "allergies": ["青霉素"],
        "medication_habits": "早上8点吃药"
    }
    resp3 = client.put("/api/v1/auth/profile", json=update_data, headers=headers)
    assert resp3.status_code == 200
    updated_profile = resp3.json()["profile"]
    assert "高血压" in updated_profile["chronic_diseases"]
