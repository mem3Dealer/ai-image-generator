import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import Barrier

import pytest

from app.db import connect, initialize_database
from app.errors import ApiError
from app.generations import (
    NewGeneration,
    GenerationOptions,
    create_generation,
    get_generation,
    list_generations,
    mark_completed,
    parse_generation_request,
    read_generation_image,
)
from app.users import purchase_premium

USER_ID = "6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f"
OTHER_USER_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
NOW = datetime(2026, 11, 2, 8, 0, tzinfo=timezone.utc)
ASSETS_DIR = Path(__file__).resolve().parents[1] / "assets"


def open_database(tmp_path: Path) -> tuple[sqlite3.Connection, Path]:
    images_dir = tmp_path / "images"
    images_dir.mkdir()
    database_path = tmp_path / "app.db"
    initialize_database(database_path)
    return connect(database_path), images_dir


def build_generation(prompt: str = "A city", style: str = "photorealistic", quality: str = "standard") -> NewGeneration:
    options = GenerationOptions(style=style, aspect_ratio="1:1", quality=quality)
    return NewGeneration(prompt=prompt, options=options)


def test_free_user_creates_standard_generation(tmp_path: Path) -> None:
    connection, _images_dir = open_database(tmp_path)
    try:
        payload = create_generation(connection, USER_ID, build_generation(), NOW)
    finally:
        connection.close()
    assert payload["status"] == "pending"
    assert payload["id"]


def test_free_user_premium_option_does_not_insert(tmp_path: Path) -> None:
    connection, _images_dir = open_database(tmp_path)
    try:
        with pytest.raises(ApiError) as caught:
            create_generation(connection, USER_ID, build_generation(style="anime"), NOW)
        total = connection.execute("SELECT COUNT(*) AS total FROM generations").fetchone()
    finally:
        connection.close()
    assert caught.value.status_code == 403
    assert caught.value.code == "PREMIUM_REQUIRED"
    assert caught.value.message == "This option requires a Premium subscription"
    assert total is not None
    assert total["total"] == 0


def test_premium_user_can_use_premium_options(tmp_path: Path) -> None:
    connection, _images_dir = open_database(tmp_path)
    try:
        purchase_premium(connection, USER_ID, NOW)
        anime = create_generation(connection, USER_ID, build_generation(style="anime"), NOW)
        hd = create_generation(connection, USER_ID, build_generation(quality="hd"), NOW)
    finally:
        connection.close()
    assert anime["status"] == "pending"
    assert hd["status"] == "pending"


@pytest.mark.parametrize("prompt", ["", "   ", "\n\t"])
def test_blank_prompt_is_rejected(prompt: str) -> None:
    with pytest.raises(ApiError) as caught:
        parse_generation_request({"prompt": prompt, "options": {"style": "photorealistic", "aspectRatio": "1:1", "quality": "standard"}})
    assert caught.value.status_code == 400
    assert caught.value.code == "INVALID_REQUEST"
    assert caught.value.message == "Prompt is required"


@pytest.mark.parametrize(
    ("field", "value"),
    [("style", "oil"), ("aspectRatio", "4:5"), ("quality", "ultra")],
)
def test_unknown_option_is_rejected(field: str, value: str) -> None:
    options = {"style": "photorealistic", "aspectRatio": "1:1", "quality": "standard"}
    options[field] = value
    with pytest.raises(ApiError) as caught:
        parse_generation_request({"prompt": "A city", "options": options})
    assert caught.value.status_code == 400
    assert caught.value.code == "INVALID_REQUEST"


def test_generation_stays_processing_before_ready(tmp_path: Path) -> None:
    connection, images_dir = open_database(tmp_path)
    try:
        created = create_generation(connection, USER_ID, build_generation(), NOW)
        first = get_generation(connection, USER_ID, created["id"], NOW, ASSETS_DIR, images_dir)
        second = get_generation(connection, USER_ID, created["id"], NOW, ASSETS_DIR, images_dir)
        history = list_generations(connection, USER_ID, NOW, ASSETS_DIR, images_dir)
    finally:
        connection.close()
    assert first == {"id": created["id"], "status": "processing"}
    assert second == first
    assert history["generations"][0]["status"] == "processing"
    assert history["generations"][0]["imageUrl"] is None
    assert history["generations"][0]["error"] is None


def test_trigger_error_fails_without_copying_image(tmp_path: Path) -> None:
    connection, images_dir = open_database(tmp_path)
    later = NOW + timedelta(seconds=4)
    try:
        created = create_generation(connection, USER_ID, build_generation(prompt="trigger-error"), NOW)
        first = get_generation(connection, USER_ID, created["id"], later, ASSETS_DIR, images_dir)
        second = get_generation(connection, USER_ID, created["id"], later, ASSETS_DIR, images_dir)
    finally:
        connection.close()
    assert first["status"] == "failed"
    assert first["error"] == {"code": "GENERATION_FAILED", "message": "Image generation failed"}
    assert second == first
    assert list(images_dir.glob("*.png")) == []


def test_padded_trigger_prompt_completes(tmp_path: Path) -> None:
    connection, images_dir = open_database(tmp_path)
    later = NOW + timedelta(seconds=4)
    try:
        created = create_generation(connection, USER_ID, build_generation(prompt=" trigger-error "), NOW)
        payload = get_generation(connection, USER_ID, created["id"], later, ASSETS_DIR, images_dir)
    finally:
        connection.close()
    assert payload["status"] == "completed"


def test_completed_generation_is_stable(tmp_path: Path) -> None:
    connection, images_dir = open_database(tmp_path)
    later = NOW + timedelta(seconds=4)
    try:
        created = create_generation(connection, USER_ID, build_generation(style="digital-art"), NOW)
        first = get_generation(connection, USER_ID, created["id"], later, ASSETS_DIR, images_dir)
        image_path = images_dir / f"{created['id']}.png"
        first_bytes = image_path.read_bytes()
        first_mtime = image_path.stat().st_mtime_ns
        second = get_generation(connection, USER_ID, created["id"], later, ASSETS_DIR, images_dir)
        downloaded = read_generation_image(connection, USER_ID, created["id"], images_dir)
    finally:
        connection.close()
    assert first["status"] == "completed"
    assert first["imageUrl"] == f"/static/generated/{created['id']}.png"
    assert second == first
    assert image_path.stat().st_mtime_ns == first_mtime
    assert downloaded == first_bytes
    assert downloaded == (ASSETS_DIR / "digital-art.png").read_bytes()


def test_other_user_cannot_read_generation_or_image(tmp_path: Path) -> None:
    connection, images_dir = open_database(tmp_path)
    later = NOW + timedelta(seconds=4)
    try:
        created = create_generation(connection, USER_ID, build_generation(), NOW)
        get_generation(connection, USER_ID, created["id"], later, ASSETS_DIR, images_dir)
        with pytest.raises(ApiError) as status_error:
            get_generation(connection, OTHER_USER_ID, created["id"], later, ASSETS_DIR, images_dir)
        with pytest.raises(ApiError) as image_error:
            read_generation_image(connection, OTHER_USER_ID, created["id"], images_dir)
    finally:
        connection.close()
    assert status_error.value.status_code == 404
    assert status_error.value.code == "NOT_FOUND"
    assert image_error.value.status_code == 404
    assert image_error.value.code == "NOT_FOUND"


def test_history_is_isolated_and_newest_first(tmp_path: Path) -> None:
    connection, images_dir = open_database(tmp_path)
    try:
        create_generation(connection, USER_ID, build_generation(prompt="older"), NOW)
        create_generation(connection, OTHER_USER_ID, build_generation(prompt="foreign"), NOW)
        create_generation(connection, USER_ID, build_generation(prompt="newer"), NOW + timedelta(seconds=1))
        history = list_generations(connection, USER_ID, NOW + timedelta(seconds=1), ASSETS_DIR, images_dir)
    finally:
        connection.close()
    prompts = [item["prompt"] for item in history["generations"]]
    assert prompts == ["newer", "older"]


def test_overdue_generation_completes_on_a_new_connection(tmp_path: Path) -> None:
    database_path = tmp_path / "app.db"
    images_dir = tmp_path / "images"
    images_dir.mkdir()
    initialize_database(database_path)
    connection = connect(database_path)
    try:
        created = create_generation(connection, USER_ID, build_generation(style="digital-art"), NOW)
    finally:
        connection.close()
    restarted = connect(database_path)
    try:
        payload = get_generation(
            restarted,
            USER_ID,
            created["id"],
            NOW + timedelta(seconds=4),
            ASSETS_DIR,
            images_dir,
        )
    finally:
        restarted.close()
    assert payload["status"] == "completed"
    assert (images_dir / f"{created['id']}.png").read_bytes() == (ASSETS_DIR / "digital-art.png").read_bytes()


def test_parallel_completion_publishes_one_image(tmp_path: Path) -> None:
    database_path = tmp_path / "app.db"
    images_dir = tmp_path / "images"
    images_dir.mkdir()
    initialize_database(database_path)
    connection = connect(database_path)
    try:
        created = create_generation(connection, USER_ID, build_generation(), NOW)
    finally:
        connection.close()
    barrier = Barrier(2)
    later = NOW + timedelta(seconds=4)

    def finish_once() -> dict[str, object]:
        own = connect(database_path)
        try:
            barrier.wait(timeout=5)
            return get_generation(own, USER_ID, created["id"], later, ASSETS_DIR, images_dir)
        finally:
            own.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _index: finish_once(), (0, 1)))
    assert results[0]["status"] == "completed"
    assert results[1] == results[0]
    assert list(images_dir.glob("*.png")) == [images_dir / f"{created['id']}.png"]
    assert list(images_dir.glob("*.tmp")) == []


def test_conditional_complete_has_one_winner(tmp_path: Path) -> None:
    database_path = tmp_path / "app.db"
    initialize_database(database_path)
    connection = connect(database_path)
    generation_id = "6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f"
    try:
        create_generation(connection, USER_ID, build_generation(), NOW)
        row = connection.execute("SELECT id FROM generations").fetchone()
        assert row is not None
        generation_id = str(row["id"])
    finally:
        connection.close()
    barrier = Barrier(2)

    def attempt_complete() -> bool:
        own = connect(database_path)
        try:
            barrier.wait(timeout=5)
            own.execute("BEGIN IMMEDIATE")
            try:
                won = mark_completed(own, generation_id, f"/static/generated/{generation_id}.png")
                own.commit()
            except Exception:
                own.rollback()
                raise
            return won
        finally:
            own.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        wins = list(pool.map(lambda _index: attempt_complete(), (0, 1)))
    assert wins.count(True) == 1
