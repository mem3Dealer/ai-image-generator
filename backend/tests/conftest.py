from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.settings import Settings

USER_A = "6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f"
USER_B = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
START = datetime(2026, 11, 2, 8, 0, tzinfo=timezone.utc)


class ManualClock:
    def __init__(self, moment: datetime) -> None:
        self.moment = moment

    def now(self) -> datetime:
        return self.moment


@pytest.fixture
def clock() -> ManualClock:
    return ManualClock(START)


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        database_path=tmp_path / "data" / "app.db",
        images_dir=tmp_path / "data" / "images",
        assets_dir=Path(__file__).resolve().parents[1] / "assets",
    )


@pytest.fixture
def client(settings: Settings, clock: ManualClock) -> TestClient:
    application = create_app(settings, clock)
    with TestClient(application) as test_client:
        yield test_client


def user_headers(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}


def generation_body(
    prompt: str = "A futuristic city at sunset",
    style: str = "photorealistic",
    aspect_ratio: str = "1:1",
    quality: str = "standard",
) -> dict[str, object]:
    return {
        "prompt": prompt,
        "options": {"style": style, "aspectRatio": aspect_ratio, "quality": quality},
    }
