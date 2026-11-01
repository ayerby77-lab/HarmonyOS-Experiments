"""模型接口测试：版本信息与缺失文件处理。"""
from __future__ import annotations

from fastapi.testclient import TestClient

from tests.conftest import auth_headers


def test_model_version_requires_auth(client: TestClient) -> None:
    response = client.get("/api/models/version")
    assert response.status_code == 401
    assert response.json()["code"] == "TOKEN_MISSING"


def test_model_version_seeded_from_config(client: TestClient) -> None:
    headers = auth_headers(client)
    response = client.get("/api/models/version", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["modelId"] == "yolov13n-coco-640-opset18"
    assert body["version"] == "1.0.0"
    assert len(body["sha256"]) == 64
    assert body["downloadUrl"] == "/api/models/download"
    assert body["inputWidth"] == 640 and body["inputHeight"] == 640


def test_model_download_missing_file_returns_404(client: TestClient) -> None:
    headers = auth_headers(client)
    response = client.get("/api/models/download", headers=headers)
    assert response.status_code == 404
    assert response.json()["code"] == "MODEL_NOT_FOUND"
