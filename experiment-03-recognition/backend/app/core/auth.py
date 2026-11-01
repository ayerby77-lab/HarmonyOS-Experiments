"""鉴权依赖：从 Bearer 令牌解析当前设备。

所有业务路由通过 Depends(get_current_device) 获取设备；失败统一 401。
"""
from __future__ import annotations

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.errors import ErrorCode, unauthorized
from app.models.device import Device
from app.services.auth_service import ACCESS_TOKEN_TYPE, decode_token

_bearer_scheme = HTTPBearer(auto_error=False, description="设备登录后获得的 access 令牌")


def get_current_device(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer_scheme),
    db: Session = Depends(get_db),
) -> Device:
    if credentials is None or not credentials.credentials:
        raise unauthorized(ErrorCode.TOKEN_MISSING, "缺少访问令牌", "Authorization: Bearer <token>")
    claims = decode_token(credentials.credentials, ACCESS_TOKEN_TYPE)
    device = db.get(Device, claims["sub"])
    if device is None:
        raise unauthorized(ErrorCode.TOKEN_INVALID, "令牌对应的设备不存在")
    if not device.active:
        raise unauthorized(ErrorCode.DEVICE_DISABLED, "设备已停用")
    return device
