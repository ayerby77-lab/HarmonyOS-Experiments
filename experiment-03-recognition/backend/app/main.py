"""FastAPI 应用入口：健康检查 + 鉴权 / 模型 / 记录业务路由。

启动时建表（开发期 create_all）并登记当前模型版本。
业务接口统一错误结构：{"code", "message", "detail"}。
"""
from __future__ import annotations

import json
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.api import auth as auth_api
from app.api import models as models_api
from app.api import records as records_api
from app.core.config import get_settings
from app.core.database import get_session_factory, init_db
from app.core.errors import ApiError, ErrorCode
from app.services import model_service


@asynccontextmanager
async def _lifespan(_: FastAPI):
    init_db()
    session = get_session_factory()()
    try:
        model_service.ensure_seed_model(session)
    finally:
        session.close()
    yield


def create_app() -> FastAPI:
    settings = get_settings()
    # /docs 仅在开发环境暴露
    docs_url = None if settings.is_production else "/docs"
    openapi_url = None if settings.is_production else "/openapi.json"
    app = FastAPI(
        title="智能物品识别助手 API",
        version="0.3.0",
        lifespan=_lifespan,
        docs_url=docs_url,
        redoc_url=None,
        openapi_url=openapi_url,
    )

    @app.exception_handler(ApiError)
    async def _handle_api_error(_: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.to_payload())

    @app.exception_handler(RequestValidationError)
    async def _handle_validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        detail = json.dumps(exc.errors(), ensure_ascii=False, default=str)[:800]
        payload = {"code": ErrorCode.VALIDATION_ERROR.value, "message": "请求参数不合法", "detail": detail}
        return JSONResponse(status_code=422, content=payload)

    @app.get("/health", tags=["health"])
    def health() -> dict[str, str]:
        return {"status": "ok"}

    app.include_router(auth_api.router)
    app.include_router(models_api.router)
    app.include_router(records_api.router)
    app.include_router(records_api.statistics_router)
    return app


app = create_app()
