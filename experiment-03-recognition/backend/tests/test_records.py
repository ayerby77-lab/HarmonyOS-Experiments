"""记录接口测试：幂等上传、校验、筛选与分页。"""
from __future__ import annotations

from fastapi.testclient import TestClient

from tests.conftest import auth_headers, make_detection, make_record


def upload(client: TestClient, headers: dict[str, str], records: list[dict]) -> dict:
    response = client.post(
        "/api/records", json={"schemaVersion": 1, "records": records}, headers=headers
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_upload_creates_records(client: TestClient) -> None:
    headers = auth_headers(client)
    record = make_record("rec_1000_0001", 1000, [make_detection("rec_1000_0001", 0)])
    body = upload(client, headers, [record])
    result = body["results"][0]
    assert result["recordId"] == "rec_1000_0001"
    assert result["status"] == "created"
    assert result["serverRevision"] == "1"


def test_upload_is_idempotent(client: TestClient) -> None:
    headers = auth_headers(client)
    record = make_record("rec_1000_0001", 1000, [make_detection("rec_1000_0001", 0)])
    upload(client, headers, [record])
    body = upload(client, headers, [record])
    assert body["results"][0]["status"] == "duplicate"
    assert body["results"][0]["serverRevision"] == "1"
    assert client.get("/api/records", headers=headers).json()["total"] == 1


def test_upload_conflict_does_not_overwrite(client: TestClient) -> None:
    headers = auth_headers(client)
    first = make_record("rec_1000_0001", 1000, [make_detection("rec_1000_0001", 0)])
    upload(client, headers, [first])
    conflicting = make_record("rec_1000_0001", 2000, [make_detection("rec_1000_0001", 0)])
    body = upload(client, headers, [conflicting])
    assert body["results"][0]["status"] == "conflict"
    assert body["results"][0]["code"] == "RECORD_CONFLICT"

    page = client.get("/api/records", headers=headers).json()
    assert page["total"] == 1
    # 保留首次写入的 recognizedAtMs
    assert page["items"][0]["recognizedAtMs"] == 1000


def test_upload_invalid_count_mismatch(client: TestClient) -> None:
    headers = auth_headers(client)
    record = make_record(
        "rec_1000_0001", 1000, [make_detection("rec_1000_0001", 0)], raw_detection_count=3
    )
    body = upload(client, headers, [record])
    assert body["results"][0]["status"] == "invalid"
    assert body["results"][0]["code"] == "RECORD_INVALID"
    assert client.get("/api/records", headers=headers).json()["total"] == 0


def test_upload_partial_success(client: TestClient) -> None:
    headers = auth_headers(client)
    good = make_record("rec_1000_0001", 1000, [make_detection("rec_1000_0001", 0)])
    bad = make_record("rec_2000_0002", 2000, [], raw_detection_count=1)
    body = upload(client, headers, [good, bad])
    statuses = [item["status"] for item in body["results"]]
    assert statuses == ["created", "invalid"]


def test_unsupported_batch_schema_version(client: TestClient) -> None:
    headers = auth_headers(client)
    record = make_record("rec_1000_0001", 1000, [])
    response = client.post(
        "/api/records", json={"schemaVersion": 2, "records": [record]}, headers=headers
    )
    assert response.status_code == 422
    assert response.json()["code"] == "SCHEMA_VERSION_UNSUPPORTED"


def test_time_filter_is_closed_interval(client: TestClient) -> None:
    headers = auth_headers(client)
    upload(
        client,
        headers,
        [
            make_record("rec_1000_0001", 1000, [make_detection("rec_1000_0001", 0)]),
            make_record("rec_2000_0002", 2000, [make_detection("rec_2000_0002", 0)]),
            make_record("rec_3000_0003", 3000, [make_detection("rec_3000_0003", 0)]),
        ],
    )
    page = client.get("/api/records?fromMs=2000&toMs=2000", headers=headers).json()
    assert page["total"] == 1
    assert page["items"][0]["recordId"] == "rec_2000_0002"


def test_class_filter_uses_final_and_alive_boxes(client: TestClient) -> None:
    headers = auth_headers(client)
    cup = make_detection("rec_1000_0001", 0, class_id=41, label="cup")
    dog_deleted = make_detection("rec_2000_0002", 0, class_id=18, label="dog", deleted=True)
    car = make_detection("rec_3000_0003", 0, class_id=2, label="car")
    upload(
        client,
        headers,
        [
            make_record("rec_1000_0001", 1000, [cup]),
            make_record("rec_2000_0002", 2000, [dog_deleted]),
            make_record("rec_3000_0003", 3000, [car]),
        ],
    )
    cup_page = client.get("/api/records?classId=41", headers=headers).json()
    assert [item["recordId"] for item in cup_page["items"]] == ["rec_1000_0001"]
    dog_page = client.get("/api/records?classId=18", headers=headers).json()
    assert dog_page["total"] == 0


def test_counts_recomputed_excluding_deleted(client: TestClient) -> None:
    headers = auth_headers(client)
    detections = [
        make_detection("rec_1000_0001", 0, class_id=41, label="cup"),
        make_detection("rec_1000_0001", 1, class_id=41, label="cup"),
        make_detection("rec_1000_0001", 2, class_id=18, label="dog", deleted=True),
        make_detection("rec_1000_0001", 3, class_id=2, label="car"),
    ]
    upload(client, headers, [make_record("rec_1000_0001", 1000, detections)])
    page = client.get("/api/records", headers=headers).json()
    counts = page["items"][0]["counts"]
    assert counts == [
        {"classId": 41, "label": "cup", "count": 2},
        {"classId": 2, "label": "car", "count": 1},
    ]


def test_pagination_stability_and_has_more(client: TestClient) -> None:
    headers = auth_headers(client)
    # 同毫秒记录依赖 recordId 降序作为次级排序，保证翻页稳定
    records = [
        make_record("rec_5000_0001", 5000, []),
        make_record("rec_5000_0002", 5000, []),
        make_record("rec_5000_0003", 5000, []),
    ]
    upload(client, headers, records)

    first = client.get("/api/records?page=1&pageSize=2", headers=headers).json()
    second = client.get("/api/records?page=2&pageSize=2", headers=headers).json()
    assert first["total"] == 3
    assert first["hasMore"] is True
    assert len(first["items"]) == 2
    assert second["hasMore"] is False
    assert len(second["items"]) == 1
    ids = [item["recordId"] for item in first["items"] + second["items"]]
    assert len(set(ids)) == 3
    assert ids == ["rec_5000_0003", "rec_5000_0002", "rec_5000_0001"]


def test_source_filter_and_invalid_range(client: TestClient) -> None:
    headers = auth_headers(client)
    upload(
        client,
        headers,
        [
            make_record("rec_1000_0001", 1000, [], image_origin="camera"),
            make_record("rec_2000_0002", 2000, [], image_origin="gallery"),
        ],
    )
    gallery = client.get("/api/records?source=gallery", headers=headers).json()
    assert [item["recordId"] for item in gallery["items"]] == ["rec_2000_0002"]

    response = client.get("/api/records?fromMs=3000&toMs=2000", headers=headers)
    assert response.status_code == 400
    assert response.json()["code"] == "VALIDATION_ERROR"


# --- 记录详情 GET /api/records/{recordId} ---


def test_detail_returns_detections_ordered(client: TestClient) -> None:
    headers = auth_headers(client)
    detections = [
        make_detection("rec_1000_0001", 0, class_id=41, label="cup"),
        make_detection("rec_1000_0001", 1, class_id=18, label="dog", deleted=True),
        make_detection("rec_1000_0001", 2, class_id=2, label="car"),
    ]
    upload(client, headers, [make_record("rec_1000_0001", 1000, detections)])

    response = client.get("/api/records/rec_1000_0001", headers=headers)
    assert response.status_code == 200, response.text
    detail = response.json()
    assert detail["recordId"] == "rec_1000_0001"
    assert detail["revision"] == 1
    assert detail["rawDetectionCount"] == 3
    assert [d["rawIndex"] for d in detail["detections"]] == [0, 1, 2]
    assert detail["detections"][1]["deleted"] is True
    # counts 排除 deleted；count 相同按 classId 升序
    assert detail["counts"] == [
        {"classId": 2, "label": "car", "count": 1},
        {"classId": 41, "label": "cup", "count": 1},
    ]


def test_detail_not_found(client: TestClient) -> None:
    headers = auth_headers(client)
    response = client.get("/api/records/rec_missing", headers=headers)
    assert response.status_code == 404
    assert response.json()["code"] == "RECORD_NOT_FOUND"


def test_detail_isolated_by_device(client: TestClient) -> None:
    headers_a = auth_headers(client, device_id="device-a")
    upload(
        client,
        headers_a,
        [make_record("rec_1000_0001", 1000, [make_detection("rec_1000_0001", 0)])],
    )
    headers_b = auth_headers(client, device_id="device-b")
    response = client.get("/api/records/rec_1000_0001", headers=headers_b)
    assert response.status_code == 404
    assert response.json()["code"] == "RECORD_NOT_FOUND"


def test_detail_requires_auth(client: TestClient) -> None:
    response = client.get("/api/records/rec_1000_0001")
    assert response.status_code == 401


# --- 统计 GET /api/statistics ---


def test_statistics_empty(client: TestClient) -> None:
    headers = auth_headers(client)
    response = client.get("/api/statistics", headers=headers)
    assert response.status_code == 200, response.text
    assert response.json() == {"totalRecords": 0, "totalDetections": 0, "counts": []}


def test_statistics_excludes_deleted_and_sorts(client: TestClient) -> None:
    headers = auth_headers(client)
    upload(
        client,
        headers,
        [
            make_record(
                "rec_1000_0001",
                1000,
                [
                    make_detection("rec_1000_0001", 0, class_id=41, label="cup"),
                    make_detection("rec_1000_0001", 1, class_id=41, label="cup"),
                    make_detection("rec_1000_0001", 2, class_id=18, label="dog", deleted=True),
                ],
            ),
            # 空结果记录：计入 totalRecords，不产生类别计数
            make_record("rec_2000_0002", 2000, []),
            make_record(
                "rec_3000_0003",
                3000,
                [make_detection("rec_3000_0003", 0, class_id=2, label="car")],
            ),
        ],
    )
    stats = client.get("/api/statistics", headers=headers).json()
    assert stats["totalRecords"] == 3
    assert stats["totalDetections"] == 3
    assert stats["counts"] == [
        {"classId": 41, "label": "cup", "count": 2},
        {"classId": 2, "label": "car", "count": 1},
    ]


def test_statistics_time_range(client: TestClient) -> None:
    headers = auth_headers(client)
    upload(
        client,
        headers,
        [
            make_record("rec_1000_0001", 1000, [make_detection("rec_1000_0001", 0)]),
            make_record("rec_2000_0002", 2000, [make_detection("rec_2000_0002", 0)]),
        ],
    )
    stats = client.get("/api/statistics?fromMs=2000&toMs=2000", headers=headers).json()
    assert stats["totalRecords"] == 1
    assert stats["totalDetections"] == 1
    assert stats["counts"] == [{"classId": 41, "label": "cup", "count": 1}]

    response = client.get("/api/statistics?fromMs=3000&toMs=2000", headers=headers)
    assert response.status_code == 400
    assert response.json()["code"] == "VALIDATION_ERROR"


def test_statistics_requires_auth(client: TestClient) -> None:
    response = client.get("/api/statistics")
    assert response.status_code == 401
