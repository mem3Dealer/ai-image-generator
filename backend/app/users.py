import re
import sqlite3
from datetime import datetime

from app.clock import format_timestamp
from app.errors import ApiError

UUID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def parse_user_id(raw_user_id: str | None) -> str:
    if raw_user_id is None:
        raise ApiError(400, "USER_ID_REQUIRED", "X-User-Id header is required")
    if UUID_PATTERN.fullmatch(raw_user_id) is None:
        raise ApiError(400, "INVALID_USER_ID", "X-User-Id must be a valid UUID")
    return raw_user_id.lower()


def ensure_user(connection: sqlite3.Connection, user_id: str, now: datetime) -> str:
    created_at = format_timestamp(now)
    connection.execute(
        "INSERT OR IGNORE INTO users (id, subscription_status, created_at) VALUES (?, 'free', ?)",
        (user_id, created_at),
    )
    row = connection.execute(
        "SELECT subscription_status FROM users WHERE id = ?",
        (user_id,),
    ).fetchone()
    if row is None:
        raise ApiError(500, "INTERNAL_ERROR", "Internal server error")
    return str(row["subscription_status"])


def register_user(connection: sqlite3.Connection, user_id: str, now: datetime) -> str:
    connection.execute("BEGIN IMMEDIATE")
    try:
        status = ensure_user(connection, user_id, now)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    return status


def get_subscription(connection: sqlite3.Connection, user_id: str, now: datetime) -> dict[str, str]:
    connection.execute("BEGIN IMMEDIATE")
    try:
        status = ensure_user(connection, user_id, now)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    return {"status": status}


def purchase_premium(connection: sqlite3.Connection, user_id: str, now: datetime) -> dict[str, str]:
    connection.execute("BEGIN IMMEDIATE")
    try:
        ensure_user(connection, user_id, now)
        connection.execute(
            "UPDATE users SET subscription_status = 'premium' WHERE id = ?",
            (user_id,),
        )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    return {"status": "premium"}
