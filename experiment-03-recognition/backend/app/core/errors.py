"""统一错误码与错误响应。

错误码与客户端错误码的对应关系：
- 客户端 RecognitionErrorCode（MODEL_MISSING / MODEL_INVALID / UNSUPPORTED_ABI /
  IMAGE_INVALID / INFERENCE_FAILED / CANCELLED）属于端侧推理，不由后端返回。
- 客户端 RecordErrorCode（RECORD_NOT_FOUND / DB_INIT_FAILED / DB_WRITE_FAILED /
  IMAGE_COPY_FAILED / THUMBNAIL_FAILED）中，RECORD_NOT_FOUND 与服务端同名；
  DB_INIT_FAILED 对应服务端 SERVICE_UNAVAILABLE；DB_WRITE_FAILED 对应 STORAGE_WRITE_FAILED。
- 服务端新增鉴权与模型相关错误码，客户端上传层按 code 分类处理。
"""
from __future__ import annotations

from enum import StrEnum


class ErrorCode(StrEnum):
    # 鉴权
    TOKEN_MISSING = "TOKEN_MISSING"
    TOKEN_INVALID = "TOKEN_INVALID"
    TOKEN_EXPIRED = "TOKEN_EXPIRED"
    DEVICE_AUTH_FAILED = "DEVICE_AUTH_FAILED"
    DEVICE_DISABLED = "DEVICE_DISABLED"

    # 记录
    RECORD_NOT_FOUND = "RECORD_NOT_FOUND"
    RECORD_CONFLICT = "RECORD_CONFLICT"
    RECORD_INVALID = "RECORD_INVALID"
    SCHEMA_VERSION_UNSUPPORTED = "SCHEMA_VERSION_UNSUPPORTED"

    # 模型
    MODEL_NOT_FOUND = "MODEL_NOT_FOUND"
    MODEL_INVALID = "MODEL_INVALID"

    # 通用
    VALIDATION_ERROR = "VALIDATION_ERROR"
    STORAGE_WRITE_FAILED = "STORAGE_WRITE_FAILED"
    SERVICE_UNAVAILABLE = "SERVICE_UNAVAILABLE"
    INTERNAL_ERROR = "INTERNAL_ERROR"


class ApiError(Exception):
    """业务异常；由 main.py 的异常处理器转换为统一 JSON 结构。"""

    def __init__(
        self,
        status_code: int,
        code: ErrorCode | str,
        message: str,
        detail: str = "",
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = str(code)
        self.message = message
        self.detail = detail

    def to_payload(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message, "detail": self.detail}


def unauthorized(code: ErrorCode, message: str, detail: str = "") -> ApiError:
    return ApiError(401, code, message, detail)
