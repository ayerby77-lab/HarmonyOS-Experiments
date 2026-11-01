"""应用配置：从环境变量加载，带开发环境安全默认值。

生产部署必须通过环境变量覆盖 JWT_SECRET / DEVICE_SECRET，并设置 APP_ENV=production。
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

# backend/app/core/config.py -> backend/
BACKEND_ROOT = Path(__file__).resolve().parents[2]
# 仓库根目录（backend 的上一级）
REPO_ROOT = BACKEND_ROOT.parent
DEFAULT_MODEL_PATH = (
    REPO_ROOT / "app" / "entry" / "src" / "main" / "resources" / "rawfile" / "models" / "yolov13n.onnx"
)


@dataclass(frozen=True)
class Settings:
    """运行期配置。字段均可用同名大写环境变量覆盖。"""

    app_env: str = field(default_factory=lambda: os.environ.get("APP_ENV", "development"))
    jwt_secret: str = field(
        default_factory=lambda: os.environ.get("JWT_SECRET", "dev-insecure-jwt-secret-change-me")
    )
    jwt_algorithm: str = "HS256"
    access_token_ttl_s: int = field(
        default_factory=lambda: int(os.environ.get("ACCESS_TOKEN_TTL_S", "1800"))
    )
    refresh_token_ttl_s: int = field(
        default_factory=lambda: int(os.environ.get("REFRESH_TOKEN_TTL_S", "604800"))
    )
    # 设备首次接入的引导密钥；设备已存在时使用设备自身密钥哈希校验。
    device_secret: str = field(
        default_factory=lambda: os.environ.get("DEVICE_SECRET", "dev-device-secret-change-me")
    )
    db_path: Path = field(
        default_factory=lambda: Path(os.environ.get("DB_PATH", str(BACKEND_ROOT / "data" / "app.db")))
    )

    model_id: str = field(
        default_factory=lambda: os.environ.get("MODEL_ID", "yolov13n-coco-640-opset18")
    )
    model_version: str = field(default_factory=lambda: os.environ.get("MODEL_VERSION", "1.0.0"))
    model_sha256: str = field(
        default_factory=lambda: os.environ.get(
            "MODEL_SHA256", "f39e5a3b1763423b1e60769e81b08a5da012677dce0248f4b4a95c5ad5cb799b"
        )
    )
    model_path: Path = field(
        default_factory=lambda: Path(os.environ.get("MODEL_PATH", str(DEFAULT_MODEL_PATH)))
    )

    @property
    def is_production(self) -> bool:
        return self.app_env.lower() == "production"

    @property
    def database_url(self) -> str:
        override = os.environ.get("DATABASE_URL")
        if override:
            return override
        return f"sqlite:///{self.db_path}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """进程级配置单例；测试可通过 get_settings.cache_clear() 重置。"""
    return Settings()
