"""识别记录与检测项模型。

幂等键为 (device_id, record_id)：recordId 由客户端离线生成，不同设备可能重复，
因此不能只用 record_id 建唯一约束。
"""
from __future__ import annotations

from sqlalchemy import (
    BigInteger,
    Boolean,
    Float,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base


class Record(Base):
    __tablename__ = "records"
    __table_args__ = (
        UniqueConstraint("device_id", "record_id", name="uq_records_device_record"),
        {"comment": "识别记录，按设备隔离"},
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    device_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("devices.device_id"), nullable=False, index=True
    )
    record_id: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    # 规范化载荷哈希，用于同 recordId 的重复/冲突判定
    payload_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    revision: Mapped[int] = mapped_column(Integer, nullable=False, default=1)

    schema_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    request_id: Mapped[str] = mapped_column(String(64), nullable=False)
    image_id: Mapped[str] = mapped_column(String(64), nullable=False)
    captured_at_ms: Mapped[int] = mapped_column(BigInteger, nullable=False)
    recognized_at_ms: Mapped[int] = mapped_column(BigInteger, nullable=False, index=True)
    saved_at_ms: Mapped[int] = mapped_column(BigInteger, nullable=False)
    edited_at_ms: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    image_width: Mapped[int] = mapped_column(Integer, nullable=False)
    image_height: Mapped[int] = mapped_column(Integer, nullable=False)
    is_mirrored: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    image_origin: Mapped[str] = mapped_column(String(16), nullable=False)

    model_id: Mapped[str] = mapped_column(String(64), nullable=False)
    model_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    confidence_threshold: Mapped[float] = mapped_column(Float, nullable=False)
    iou_threshold: Mapped[float] = mapped_column(Float, nullable=False)
    max_detections: Mapped[int] = mapped_column(Integer, nullable=False)
    execution_mode: Mapped[str] = mapped_column(String(16), nullable=False)

    preprocess_ms: Mapped[float] = mapped_column(Float, nullable=False)
    inference_ms: Mapped[float] = mapped_column(Float, nullable=False)
    postprocess_ms: Mapped[float] = mapped_column(Float, nullable=False)
    total_ms: Mapped[float] = mapped_column(Float, nullable=False)
    cold_start: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    model_load_ms: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)

    raw_detection_count: Mapped[int] = mapped_column(Integer, nullable=False)
    edited: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # 服务端接收时间，与客户端 savedAtMs 区分
    received_at_ms: Mapped[int] = mapped_column(BigInteger, nullable=False)

    detections: Mapped[list["RecordDetection"]] = relationship(
        back_populates="record", cascade="all, delete-orphan", passive_deletes=True
    )


class RecordDetection(Base):
    __tablename__ = "record_detections"
    __table_args__ = (
        UniqueConstraint("record_pk", "raw_index", name="uq_detections_record_raw_index"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    record_pk: Mapped[int] = mapped_column(
        Integer, ForeignKey("records.id", ondelete="CASCADE"), nullable=False, index=True
    )
    detection_id: Mapped[str] = mapped_column(String(96), nullable=False, index=True)
    raw_index: Mapped[int] = mapped_column(Integer, nullable=False)

    raw_class_id: Mapped[int] = mapped_column(Integer, nullable=False)
    raw_label: Mapped[str] = mapped_column(String(64), nullable=False)
    class_id: Mapped[int] = mapped_column(Integer, nullable=False, index=True)
    label: Mapped[str] = mapped_column(String(64), nullable=False)
    confidence: Mapped[float] = mapped_column(Float, nullable=False)

    left: Mapped[float] = mapped_column(Float, nullable=False)
    top: Mapped[float] = mapped_column(Float, nullable=False)
    right: Mapped[float] = mapped_column(Float, nullable=False)
    bottom: Mapped[float] = mapped_column(Float, nullable=False)

    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    class_corrected: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    edited_at_ms: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

    record: Mapped[Record] = relationship(back_populates="detections")
