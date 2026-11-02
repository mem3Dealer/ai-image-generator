import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import pytest

from app.db import connect, initialize_database, prepare_storage
from app.errors import ApiError
from app.users import get_subscription, parse_user_id, purchase_premium

USER_ID = "6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f"
NOW = datetime(2026, 11, 2, 8, 0, tzinfo=timezone.utc)


def open_database(tmp_path: Path) -> sqlite3.Connection:
    database_path = tmp_path / "app.db"
    initialize_database(database_path)
    return connect(database_path)


def test_connect_does_not_create_schema(tmp_path: Path) -> None:
    database_path = tmp_path / "data" / "app.db"
    database_path.parent.mkdir()
    connection = connect(database_path)
    try:
        rows = connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).fetchall()
    finally:
        connection.close()
    assert rows == []


def test_prepare_storage_creates_directories_and_schema(tmp_path: Path) -> None:
    database_path = tmp_path / "data" / "app.db"
    images_dir = tmp_path / "data" / "images"
    prepare_storage(database_path, images_dir)
    assert images_dir.is_dir()
    assert database_path.is_file()
    connection = connect(database_path)
    try:
        names = {
            str(row["name"])
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
        }
    finally:
        connection.close()
    assert {"users", "generations"}.issubset(names)


def test_initialize_database_keeps_existing_rows(tmp_path: Path) -> None:
    database_path = tmp_path / "app.db"
    initialize_database(database_path)
    connection = connect(database_path)
    try:
        connection.execute(
            "INSERT INTO users (id, subscription_status, created_at) VALUES (?, 'free', ?)",
            (USER_ID, "2026-11-02T08:00:00Z"),
        )
    finally:
        connection.close()
    initialize_database(database_path)
    connection = connect(database_path)
    try:
        row = connection.execute(
            "SELECT subscription_status FROM users WHERE id = ?",
            (USER_ID,),
        ).fetchone()
    finally:
        connection.close()
    assert row is not None
    assert row["subscription_status"] == "free"


def test_new_user_gets_free_subscription(tmp_path: Path) -> None:
    connection = open_database(tmp_path)
    try:
        payload = get_subscription(connection, USER_ID, NOW)
    finally:
        connection.close()
    assert payload == {"status": "free"}


def test_get_subscription_returns_saved_status(tmp_path: Path) -> None:
    connection = open_database(tmp_path)
    try:
        purchase_premium(connection, USER_ID, NOW)
        payload = get_subscription(connection, USER_ID, NOW)
    finally:
        connection.close()
    assert payload == {"status": "premium"}


def test_purchase_is_idempotent(tmp_path: Path) -> None:
    connection = open_database(tmp_path)
    try:
        first = purchase_premium(connection, USER_ID, NOW)
        second = purchase_premium(connection, USER_ID, NOW)
        total = connection.execute("SELECT COUNT(*) AS total FROM users").fetchone()
    finally:
        connection.close()
    assert first == {"status": "premium"}
    assert second == {"status": "premium"}
    assert total is not None
    assert total["total"] == 1


def test_missing_user_id_is_rejected() -> None:
    with pytest.raises(ApiError) as caught:
        parse_user_id(None)
    assert caught.value.status_code == 400
    assert caught.value.code == "USER_ID_REQUIRED"


def test_invalid_user_id_is_rejected() -> None:
    with pytest.raises(ApiError) as caught:
        parse_user_id("not-a-uuid")
    assert caught.value.status_code == 400
    assert caught.value.code == "INVALID_USER_ID"
