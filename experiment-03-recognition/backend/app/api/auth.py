"""鉴权路由：设备登录与令牌刷新。"""
from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.schemas.auth import LoginRequest, RefreshRequest, TokenResponse
from app.services import auth_service

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/login", response_model=TokenResponse, summary="设备标识+密钥换取令牌")
def login(payload: LoginRequest, db: Session = Depends(get_db)) -> TokenResponse:
    pair = auth_service.login(db, payload.deviceId, payload.deviceSecret)
    return TokenResponse(
        accessToken=pair.access_token,
        refreshToken=pair.refresh_token,
        expiresIn=pair.expires_in,
        refreshExpiresIn=pair.refresh_expires_in,
    )


@router.post("/refresh", response_model=TokenResponse, summary="刷新令牌")
def refresh(payload: RefreshRequest, db: Session = Depends(get_db)) -> TokenResponse:
    pair = auth_service.refresh(db, payload.refreshToken)
    return TokenResponse(
        accessToken=pair.access_token,
        refreshToken=pair.refresh_token,
        expiresIn=pair.expires_in,
        refreshExpiresIn=pair.refresh_expires_in,
    )
