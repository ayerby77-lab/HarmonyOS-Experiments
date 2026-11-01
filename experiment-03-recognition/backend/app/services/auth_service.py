"""JWT 签发 / 校验 / 刷新，以及设备密钥校验。"""
from __future__ import annotations

import hashlib
import hmac
import time
from dataclasses import dataclass

import jwt
from jwt import ExpiredSignatureError, InvalidTokenError
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.errors import ErrorCode, unauthorized
from app.models.device import Device

ACCESS_TOKEN_TYPE = "access"
REFRESH_TOKEN_TYPE = "refresh"


@dataclass(frozen=True)
class TokenPair:
    access_token: str
    refresh_token: str
    expires_in: int
    refresh_expires_in: int


def now_ms() -> int:
    return int(time.time() * 1000)


def hash_device_secret(device_id: str, device_secret: str) -> str:
    """设备密钥单向哈希；不落明文。"""
    return hashlib.sha256(f"{device_id}:{device_secret}".encode("utf-8")).hexdigest()


def issue_tokens(device_id: str) -> TokenPair:
    settings = get_settings()
    issued_at = int(time.time())
    access_exp = issued_at + settings.access_token_ttl_s
    refresh_exp = issued_at + settings.refresh_token_ttl_s
    access = jwt.encode(
        {"sub": device_id, "typ": ACCESS_TOKEN_TYPE, "iat": issued_at, "exp": access_exp},
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    refresh = jwt.encode(
        {"sub": device_id, "typ": REFRESH_TOKEN_TYPE, "iat": issued_at, "exp": refresh_exp},
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    return TokenPair(
        access_token=access,
        refresh_token=refresh,
        expires_in=settings.access_token_ttl_s,
        refresh_expires_in=settings.refresh_token_ttl_s,
    )


def decode_token(token: str, expected_type: str) -> dict:
    """校验签名/过期/类型，失败抛 401 ApiError。"""
    settings = get_settings()
    try:
        claims = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            options={"require": ["exp", "sub", "typ"]},
        )
    except ExpiredSignatureError:
        raise unauthorized(ErrorCode.TOKEN_EXPIRED, "令牌已过期", "请使用 refresh 令牌续期")
    except InvalidTokenError as exc:
        raise unauthorized(ErrorCode.TOKEN_INVALID, "令牌无效", str(exc))
    if claims.get("typ") != expected_type:
        raise unauthorized(ErrorCode.TOKEN_INVALID, "令牌类型不正确", f"expect={expected_type}")
    return claims


def login(db: Session, device_id: str, device_secret: str) -> TokenPair:
    """设备标识 + 密钥换取令牌；未知设备可用引导密钥自动登记。"""
    settings = get_settings()
    device = db.get(Device, device_id)
    if device is None:
        if not hmac.compare_digest(device_secret, settings.device_secret):
            raise unauthorized(ErrorCode.DEVICE_AUTH_FAILED, "设备未注册或密钥错误")
        device = Device(
            device_id=device_id,
            secret_hash=hash_device_secret(device_id, device_secret),
            created_at_ms=now_ms(),
            last_login_at_ms=now_ms(),
            active=True,
        )
        db.add(device)
    else:
        if not device.active:
            raise unauthorized(ErrorCode.DEVICE_DISABLED, "设备已停用")
        expected = hash_device_secret(device_id, device_secret)
        if not hmac.compare_digest(expected, device.secret_hash):
            raise unauthorized(ErrorCode.DEVICE_AUTH_FAILED, "设备标识或密钥错误")
        device.last_login_at_ms = now_ms()
    db.commit()
    return issue_tokens(device_id)


def refresh(db: Session, refresh_token: str) -> TokenPair:
    """用 refresh 令牌换取新的 access + refresh（轮换）。"""
    claims = decode_token(refresh_token, REFRESH_TOKEN_TYPE)
    device = db.get(Device, claims["sub"])
    if device is None or not device.active:
        raise unauthorized(ErrorCode.DEVICE_DISABLED, "设备不存在或已停用")
    return issue_tokens(device.device_id)
