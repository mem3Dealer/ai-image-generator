import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from app.clock import Clock, SystemClock
from app.db import prepare_storage
from app.errors import ApiError, build_error_body
from app.routes import router
from app.settings import Settings, load_settings

logger = logging.getLogger("app")


@asynccontextmanager
async def lifespan(application: FastAPI) -> AsyncIterator[None]:
    settings: Settings = application.state.settings
    prepare_storage(settings.database_path, settings.images_dir)
    yield


def create_app(settings: Settings | None = None, clock: Clock | None = None) -> FastAPI:
    logging.basicConfig(level=logging.INFO)
    application = FastAPI(lifespan=lifespan)
    application.state.settings = settings if settings is not None else load_settings()
    application.state.clock = clock if clock is not None else SystemClock()
    application.include_router(router)
    application.add_exception_handler(ApiError, handle_api_error)
    application.add_exception_handler(Exception, handle_unexpected_error)
    return application


def handle_api_error(request: Request, error: ApiError) -> JSONResponse:
    return JSONResponse(status_code=error.status_code, content=build_error_body(error))


def handle_unexpected_error(request: Request, error: Exception) -> JSONResponse:
    if isinstance(error, ApiError):
        return handle_api_error(request, error)
    logger.exception("Unhandled error")
    unexpected = ApiError(500, "INTERNAL_ERROR", "Internal server error")
    return JSONResponse(status_code=unexpected.status_code, content=build_error_body(unexpected))


app = create_app()
