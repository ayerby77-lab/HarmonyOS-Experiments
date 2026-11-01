"""鉴权请求与响应结构。"""
from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LoginRequest(_StrictModel):
    """设备标识 + 密钥换取令牌。

    首次接入：deviceId 不存在且 deviceSecret 等于服务端 DEVICE_SECRET 时自动登记设备。
    已登记设备：deviceSecret 必须与登记时的密钥一致。
    """

    deviceId: str = Field(min_length=1, max_length=64)
    deviceSecret: str = Field(min_length=1, max_length=128)


class RefreshRequest(_StrictModel):
    refreshToken: str = Field(min_length=1)


class TokenResponse(BaseModel):
    accessToken: str
    refreshToken: str
    tokenType: str = "Bearer"
    # 秒
    expiresIn: int
    refreshExpiresIn: int
