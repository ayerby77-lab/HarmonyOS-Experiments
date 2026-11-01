"""鉴权接口测试：登录、刷新、401 处理。"""
from __future__ import annotations

from fastapi.testclient import TestClient

from tests.conftest import BOOTSTRAP_SECRET, auth_headers, login


def test_health_is_public(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_login_returns_token_pair(client: TestClient) -> None:
    body = login(client)
    assert body["tokenType"] == "Bearer"
    assert body["accessToken"]
    assert body["refreshToken"]
    assert body["expiresIn"] > 0
    assert body["refreshExpiresIn"] > body["expiresIn"]


def test_login_with_wrong_secret_after_registration(client: TestClient) -> None:
    login(client, device_id="device-a")
    response = client.post(
        "/api/auth/login",
        json={"deviceId": "device-a", "deviceSecret": "wrong-secret"},
    )
    assert response.status_code == 401
    assert response.json()["code"] == "DEVICE_AUTH_FAILED"


def test_unknown_device_with_bad_bootstrap_secret(client: TestClient) -> None:
    response = client.post(
        "/api/auth/login",
        json={"deviceId": "device-unknown", "deviceSecret": "not-the-bootstrap-secret"},
    )
    assert response.status_code == 401
    assert response.json()["code"] == "DEVICE_AUTH_FAILED"


def test_missing_token_returns_401(client: TestClient) -> None:
    response = client.get("/api/records")
    assert response.status_code == 401
    assert response.json()["code"] == "TOKEN_MISSING"


def test_invalid_token_returns_401(client: TestClient) -> None:
    response = client.get("/api/records", headers={"Authorization": "Bearer not-a-jwt"})
    assert response.status_code == 401
    assert response.json()["code"] == "TOKEN_INVALID"


def test_refresh_issues_working_access_token(client: TestClient) -> None:
    tokens = login(client)
    response = client.post("/api/auth/refresh", json={"refreshToken": tokens["refreshToken"]})
    assert response.status_code == 200
    refreshed = response.json()
    assert refreshed["accessToken"]
    headers = {"Authorization": f"Bearer {refreshed['accessToken']}"}
    assert client.get("/api/models/version", headers=headers).status_code == 200


def test_refresh_rejects_access_token(client: TestClient) -> None:
    tokens = login(client)
    response = client.post("/api/auth/refresh", json={"refreshToken": tokens["accessToken"]})
    assert response.status_code == 401
    assert response.json()["code"] == "TOKEN_INVALID"


def test_devices_are_isolated(client: TestClient) -> None:
    headers_a = auth_headers(client, device_id="device-a")
    headers_b = auth_headers(client, device_id="device-b")
    assert headers_a != headers_b
    assert client.get("/api/records", headers=headers_b).json()["total"] == 0


def test_bootstrap_secret_is_configurable(client: TestClient) -> None:
    response = client.post(
        "/api/auth/login",
        json={"deviceId": "device-boot", "deviceSecret": BOOTSTRAP_SECRET},
    )
    assert response.status_code == 200
