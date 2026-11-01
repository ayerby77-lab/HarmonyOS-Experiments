"""测试夹具：隔离的 SQLite 数据库与已启动的应用客户端。"""
from __future__ import annotations

from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient

BOOTSTRAP_SECRET = "test-bootstrap-secret"
MODEL_SHA256 = "f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b"


@pytest.fixture()
def client(tmp_path, monkeypatch) -> Generator[TestClient, None, None]:
    monkeypatch.setenv("DATABASE_URL", f"sqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("JWT_SECRET", "test-jwt-secret-at-least-32-bytes-long!!")
    monkeypatch.setenv("DEVICE_SECRET", BOOTSTRAP_SECRET)
    # 让下载测试使用不存在的文件路径，避免读取 10MB 真实模型
    monkeypatch.setenv("MODEL_PATH", str(tmp_path / "missing.onnx"))

    from app.core import config, database
    from app.main import create_app

    config.get_settings.cache_clear()
    database.get_engine.cache_clear()
    database.get_session_factory.cache_clear()

    app = create_app()
    with TestClient(app) as test_client:
        yield test_client

    config.get_settings.cache_clear()
    database.get_engine.cache_clear()
    database.get_session_factory.cache_clear()


def login(client: TestClient, device_id: str = "device-test-1", secret: str = BOOTSTRAP_SECRET) -> dict:
    response = client.post(
        "/api/auth/login", json={"deviceId": device_id, "deviceSecret": secret}
    )
    assert response.status_code == 200, response.text
    return response.json()


def auth_headers(client: TestClient, device_id: str = "device-test-1") -> dict[str, str]:
    tokens = login(client, device_id)
    return {"Authorization": f"Bearer {tokens['accessToken']}"}


def make_detection(
    record_id: str,
    raw_index: int,
    class_id: int = 41,
    label: str = "cup",
    deleted: bool = False,
) -> dict:
    return {
        "detectionId": f"{record_id}:d{raw_index}",
        "rawIndex": raw_index,
        "rawClassId": class_id,
        "rawLabel": label,
        "classId": class_id,
        "label": label,
        "confidence": 0.9,
        "left": 1.0,
        "top": 2.0,
        "right": 10.0,
        "bottom": 20.0,
        "deleted": deleted,
        "classCorrected": False,
        "editedAtMs": None,
    }


def make_record(
    record_id: str,
    recognized_ms: int,
    detections: list[dict] | None = None,
    image_origin: str = "camera",
    raw_detection_count: int | None = None,
) -> dict:
    items = detections or []
    return {
        "schemaVersion": 1,
        "recordId": record_id,
        "requestId": f"req-{record_id}",
        "imageId": f"img-{record_id}",
        "capturedAtMs": recognized_ms - 100,
        "recognizedAtMs": recognized_ms,
        "savedAtMs": recognized_ms + 10,
        "editedAtMs": None,
        "imageWidth": 640,
        "imageHeight": 480,
        "isMirrored": False,
        "imageOrigin": image_origin,
        "model": {"modelId": "yolov13n-coco-640-opset18", "sha256": MODEL_SHA256},
        "options": {
            "confidenceThreshold": 0.25,
            "iouThreshold": 0.7,
            "maxDetections": 300,
            "executionMode": "taskpool",
        },
        "timing": {
            "preprocessMs": 1.0,
            "inferenceMs": 2.0,
            "postprocessMs": 0.5,
            "totalMs": 3.5,
            "coldStart": False,
            "modelLoadMs": 0,
        },
        "rawDetectionCount": len(items) if raw_detection_count is None else raw_detection_count,
        "edited": False,
        "detections": items,
        "counts": [],
    }
