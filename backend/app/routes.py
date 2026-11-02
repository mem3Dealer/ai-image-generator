import json
import sqlite3
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response

from app.clock import Clock
from app.db import connect
from app.errors import ApiError
from app.generations import (
    create_generation,
    get_generation,
    list_generations,
    parse_generation_request,
    read_generation_image,
)
from app.settings import Settings
from app.users import UUID_PATTERN, get_subscription, parse_user_id, purchase_premium, register_user

router = APIRouter()


@dataclass(frozen=True)
class RequestScope:
    user_id: str
    connection: sqlite3.Connection
    now: datetime
    settings: Settings


def read_user_id(request: Request) -> str:
    return parse_user_id(request.headers.get("X-User-Id"))


def open_connection(request: Request) -> Iterator[sqlite3.Connection]:
    settings: Settings = request.app.state.settings
    connection = connect(settings.database_path)
    try:
        yield connection
    finally:
        connection.close()


def read_clock(request: Request) -> Clock:
    return request.app.state.clock


def build_scope(
    request: Request,
    user_id: str = Depends(read_user_id),
    connection: sqlite3.Connection = Depends(open_connection),
    clock: Clock = Depends(read_clock),
) -> RequestScope:
    now = clock.now()
    register_user(connection, user_id, now)
    settings: Settings = request.app.state.settings
    return RequestScope(user_id=user_id, connection=connection, now=now, settings=settings)


@router.get("/api/subscription")
def get_subscription_route(scope: RequestScope = Depends(build_scope)) -> dict[str, str]:
    return get_subscription(scope.connection, scope.user_id, scope.now)


@router.post("/api/subscription/purchase")
def purchase_subscription_route(scope: RequestScope = Depends(build_scope)) -> dict[str, str]:
    return purchase_premium(scope.connection, scope.user_id, scope.now)


@router.post("/api/generations")
async def create_generation_route(
    request: Request,
    scope: RequestScope = Depends(build_scope),
) -> JSONResponse:
    generation = parse_generation_request(await read_json_body(request))
    payload = create_generation(scope.connection, scope.user_id, generation, scope.now)
    return JSONResponse(status_code=201, content=payload)


@router.get("/api/generations")
def list_generations_route(scope: RequestScope = Depends(build_scope)) -> dict[str, object]:
    return list_generations(
        scope.connection,
        scope.user_id,
        scope.now,
        scope.settings.assets_dir,
        scope.settings.images_dir,
    )


@router.get("/api/generations/{generation_id}")
def get_generation_route(
    generation_id: str,
    scope: RequestScope = Depends(build_scope),
) -> dict[str, object]:
    return get_generation(
        scope.connection,
        scope.user_id,
        parse_generation_id(generation_id),
        scope.now,
        scope.settings.assets_dir,
        scope.settings.images_dir,
    )


@router.get("/static/generated/{file_name}")
def download_generation_route(
    file_name: str,
    scope: RequestScope = Depends(build_scope),
) -> Response:
    payload = read_generation_image(
        scope.connection,
        scope.user_id,
        parse_image_name(file_name),
        scope.settings.images_dir,
    )
    return Response(content=payload, media_type="image/png")


async def read_json_body(request: Request) -> object:
    raw_body = await request.body()
    if raw_body == b"":
        raise ApiError(400, "INVALID_REQUEST", "Invalid request")
    try:
        return json.loads(raw_body)
    except json.JSONDecodeError:
        raise ApiError(400, "INVALID_REQUEST", "Invalid request") from None


def parse_generation_id(generation_id: str) -> str:
    if UUID_PATTERN.fullmatch(generation_id) is None:
        raise ApiError(404, "NOT_FOUND", "Generation not found")
    return generation_id.lower()


def parse_image_name(file_name: str) -> str:
    suffix = ".png"
    if not file_name.endswith(suffix):
        raise ApiError(404, "NOT_FOUND", "Generation not found")
    return parse_generation_id(file_name[: -len(suffix)])
