import os
import shutil
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from app.clock import format_timestamp, parse_timestamp
from app.errors import ApiError
from app.users import ensure_user

READY_AFTER_SECONDS = 3
STYLES = {"photorealistic", "digital-art", "anime", "cinematic"}
ASPECT_RATIOS = {"1:1", "2:3", "16:9"}
QUALITIES = {"standard", "hd"}
PREMIUM_STYLES = {"anime", "cinematic"}
TRIGGER_PROMPT = "trigger-error"
FAILED_MESSAGE = "Image generation failed"
INSERT_PENDING = """
INSERT INTO generations (
    id, user_id, prompt, style, aspect_ratio, quality,
    status, ready_at, image_url, error_code, error_message, created_at
) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, NULL, NULL, NULL, ?)
"""


@dataclass(frozen=True)
class GenerationOptions:
    style: str
    aspect_ratio: str
    quality: str


@dataclass(frozen=True)
class NewGeneration:
    prompt: str
    options: GenerationOptions


def parse_generation_request(body: object) -> NewGeneration:
    if not isinstance(body, dict):
        raise ApiError(400, "INVALID_REQUEST", "Invalid request")
    prompt = read_prompt(body.get("prompt"))
    options = parse_options(body.get("options"))
    return NewGeneration(prompt=prompt, options=options)


def read_prompt(value: object) -> str:
    if not isinstance(value, str) or value.strip() == "":
        raise ApiError(400, "INVALID_REQUEST", "Prompt is required")
    return value


def parse_options(value: object) -> GenerationOptions:
    if not isinstance(value, dict):
        raise ApiError(400, "INVALID_REQUEST", "Invalid request")
    style = read_choice(value.get("style"), STYLES, "Unknown style")
    aspect_ratio = read_choice(value.get("aspectRatio"), ASPECT_RATIOS, "Unknown aspect ratio")
    quality = read_choice(value.get("quality"), QUALITIES, "Unknown quality")
    return GenerationOptions(style=style, aspect_ratio=aspect_ratio, quality=quality)


def read_choice(value: object, allowed: set[str], message: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise ApiError(400, "INVALID_REQUEST", message)
    return value


def requires_premium(options: GenerationOptions) -> bool:
    return options.style in PREMIUM_STYLES or options.quality == "hd"


def create_generation(
    connection: sqlite3.Connection,
    user_id: str,
    generation: NewGeneration,
    now: datetime,
) -> dict[str, str]:
    generation_id = str(uuid.uuid4())
    if not commit_generation(connection, user_id, generation_id, generation, now):
        raise ApiError(403, "PREMIUM_REQUIRED", "This option requires a Premium subscription")
    return {"id": generation_id, "status": "pending"}


def commit_generation(
    connection: sqlite3.Connection,
    user_id: str,
    generation_id: str,
    generation: NewGeneration,
    now: datetime,
) -> bool:
    connection.execute("BEGIN IMMEDIATE")
    try:
        subscription_status = ensure_user(connection, user_id, now)
        denied = requires_premium(generation.options) and subscription_status != "premium"
        if not denied:
            insert_pending(connection, generation_id, user_id, generation, now)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    return not denied


def insert_pending(
    connection: sqlite3.Connection,
    generation_id: str,
    user_id: str,
    generation: NewGeneration,
    now: datetime,
) -> None:
    connection.execute(INSERT_PENDING, pending_values(generation_id, user_id, generation, now))


def pending_values(
    generation_id: str,
    user_id: str,
    generation: NewGeneration,
    now: datetime,
) -> tuple[str, str, str, str, str, str, str, str]:
    ready_at = format_timestamp(now + timedelta(seconds=READY_AFTER_SECONDS))
    created_at = format_timestamp(now)
    return (
        generation_id,
        user_id,
        generation.prompt,
        generation.options.style,
        generation.options.aspect_ratio,
        generation.options.quality,
        ready_at,
        created_at,
    )


def get_generation(
    connection: sqlite3.Connection,
    user_id: str,
    generation_id: str,
    now: datetime,
    assets_dir: Path,
    images_dir: Path,
) -> dict[str, object]:
    connection.execute("BEGIN IMMEDIATE")
    try:
        payload = read_resolved_status(connection, user_id, generation_id, now, assets_dir, images_dir)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    return payload


def read_resolved_status(
    connection: sqlite3.Connection,
    user_id: str,
    generation_id: str,
    now: datetime,
    assets_dir: Path,
    images_dir: Path,
) -> dict[str, object]:
    row = find_owned_generation(connection, user_id, generation_id)
    if row is None:
        raise ApiError(404, "NOT_FOUND", "Generation not found")
    resolved = resolve_generation(connection, row, now, assets_dir, images_dir)
    return build_status_payload(resolved)


def list_generations(
    connection: sqlite3.Connection,
    user_id: str,
    now: datetime,
    assets_dir: Path,
    images_dir: Path,
) -> dict[str, object]:
    connection.execute("BEGIN IMMEDIATE")
    try:
        ensure_user(connection, user_id, now)
        items = resolve_history(connection, user_id, now, assets_dir, images_dir)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    return {"generations": items}


def resolve_history(
    connection: sqlite3.Connection,
    user_id: str,
    now: datetime,
    assets_dir: Path,
    images_dir: Path,
) -> list[dict[str, object]]:
    rows = list_generation_rows(connection, user_id)
    resolved = [resolve_generation(connection, row, now, assets_dir, images_dir) for row in rows]
    return [build_history_item(row) for row in resolved]


def list_generation_rows(connection: sqlite3.Connection, user_id: str) -> list[sqlite3.Row]:
    cursor = connection.execute(
        """
        SELECT * FROM generations
        WHERE user_id = ?
        ORDER BY created_at DESC, rowid DESC
        """,
        (user_id,),
    )
    return list(cursor.fetchall())


def find_owned_generation(
    connection: sqlite3.Connection,
    user_id: str,
    generation_id: str,
) -> sqlite3.Row | None:
    return connection.execute(
        "SELECT * FROM generations WHERE id = ? AND user_id = ?",
        (generation_id, user_id),
    ).fetchone()


def resolve_generation(
    connection: sqlite3.Connection,
    row: sqlite3.Row,
    now: datetime,
    assets_dir: Path,
    images_dir: Path,
) -> sqlite3.Row:
    if str(row["status"]) in {"completed", "failed"}:
        return row
    generation_id = str(row["id"])
    ready_at = parse_timestamp(str(row["ready_at"]))
    if ready_at > now.astimezone(ready_at.tzinfo).replace(microsecond=0):
        mark_processing(connection, generation_id)
        return require_generation(connection, generation_id)
    return finish_generation(connection, row, assets_dir, images_dir)


def finish_generation(
    connection: sqlite3.Connection,
    row: sqlite3.Row,
    assets_dir: Path,
    images_dir: Path,
) -> sqlite3.Row:
    generation_id = str(row["id"])
    if str(row["prompt"]) == TRIGGER_PROMPT:
        mark_failed(connection, generation_id)
        return require_generation(connection, generation_id)
    image_url = f"/static/generated/{generation_id}.png"
    if mark_completed(connection, generation_id, image_url):
        publish_image(assets_dir, images_dir, str(row["style"]), generation_id)
    return require_generation(connection, generation_id)


def mark_processing(connection: sqlite3.Connection, generation_id: str) -> None:
    connection.execute(
        "UPDATE generations SET status = 'processing' WHERE id = ? AND status = 'pending'",
        (generation_id,),
    )


def mark_failed(connection: sqlite3.Connection, generation_id: str) -> None:
    connection.execute(
        """
        UPDATE generations
        SET status = 'failed', error_code = 'GENERATION_FAILED', error_message = ?, image_url = NULL
        WHERE id = ? AND status IN ('pending', 'processing')
        """,
        (FAILED_MESSAGE, generation_id),
    )


def mark_completed(connection: sqlite3.Connection, generation_id: str, image_url: str) -> bool:
    cursor = connection.execute(
        """
        UPDATE generations
        SET status = 'completed', image_url = ?, error_code = NULL, error_message = NULL
        WHERE id = ? AND status IN ('pending', 'processing')
        """,
        (image_url, generation_id),
    )
    return cursor.rowcount == 1


def require_generation(connection: sqlite3.Connection, generation_id: str) -> sqlite3.Row:
    row = connection.execute(
        "SELECT * FROM generations WHERE id = ?",
        (generation_id,),
    ).fetchone()
    if row is None:
        raise ApiError(500, "INTERNAL_ERROR", "Internal server error")
    return row


def publish_image(assets_dir: Path, images_dir: Path, style: str, generation_id: str) -> None:
    source = assets_dir / f"{style}.png"
    temporary = images_dir / f"{generation_id}.png.tmp"
    target = images_dir / f"{generation_id}.png"
    shutil.copyfile(source, temporary)
    os.replace(temporary, target)


def build_status_payload(row: sqlite3.Row) -> dict[str, object]:
    status = str(row["status"])
    payload: dict[str, object] = {"id": str(row["id"]), "status": status}
    if status == "completed":
        payload["imageUrl"] = str(row["image_url"])
    if status == "failed":
        payload["error"] = build_stored_error(row)
    return payload


def build_history_item(row: sqlite3.Row) -> dict[str, object]:
    status = str(row["status"])
    image_url = None
    if status == "completed" and row["image_url"] is not None:
        image_url = str(row["image_url"])
    error = build_stored_error(row) if status == "failed" else None
    return {
        "id": str(row["id"]),
        "status": status,
        "prompt": str(row["prompt"]),
        "options": build_options(row),
        "imageUrl": image_url,
        "error": error,
        "createdAt": str(row["created_at"]),
    }


def build_options(row: sqlite3.Row) -> dict[str, str]:
    return {
        "style": str(row["style"]),
        "aspectRatio": str(row["aspect_ratio"]),
        "quality": str(row["quality"]),
    }


def build_stored_error(row: sqlite3.Row) -> dict[str, str]:
    return {"code": str(row["error_code"]), "message": str(row["error_message"])}


def read_generation_image(
    connection: sqlite3.Connection,
    user_id: str,
    generation_id: str,
    images_dir: Path,
) -> bytes:
    row = find_owned_generation(connection, user_id, generation_id)
    if row is None or str(row["status"]) != "completed":
        raise ApiError(404, "NOT_FOUND", "Generation not found")
    image_path = images_dir / f"{generation_id}.png"
    if not image_path.is_file():
        raise ApiError(500, "INTERNAL_ERROR", "Internal server error")
    return image_path.read_bytes()
