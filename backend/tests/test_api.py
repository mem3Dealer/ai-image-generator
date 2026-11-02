from datetime import timedelta

from fastapi.testclient import TestClient

from app.db import connect
from app.main import create_app
from app.settings import Settings
from tests.conftest import USER_A, USER_B, ManualClock, generation_body, user_headers


def test_new_user_receives_free(client: TestClient) -> None:
    response = client.get("/api/subscription", headers=user_headers(USER_A))
    assert response.status_code == 200
    assert response.json() == {"status": "free"}


def test_get_subscription_returns_current_status(client: TestClient) -> None:
    client.post("/api/subscription/purchase", headers=user_headers(USER_A))
    response = client.get("/api/subscription", headers=user_headers(USER_A))
    assert response.status_code == 200
    assert response.json() == {"status": "premium"}


def test_purchase_switches_user_to_premium(client: TestClient) -> None:
    response = client.post("/api/subscription/purchase", headers=user_headers(USER_A))
    assert response.status_code == 200
    assert response.json() == {"status": "premium"}


def test_repeat_purchase_is_idempotent(client: TestClient, settings: Settings) -> None:
    headers = user_headers(USER_A)
    first = client.post("/api/subscription/purchase", headers=headers)
    second = client.post("/api/subscription/purchase", headers=headers)
    connection = connect(settings.database_path)
    try:
        total = connection.execute("SELECT COUNT(*) AS total FROM users").fetchone()
    finally:
        connection.close()
    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json() == {"status": "premium"}
    assert second.json() == {"status": "premium"}
    assert total is not None
    assert total["total"] == 1


def test_free_user_creates_free_generation(client: TestClient) -> None:
    response = client.post("/api/generations", headers=user_headers(USER_A), json=generation_body())
    assert response.status_code == 201
    assert response.json()["status"] == "pending"
    assert response.json()["id"]


def test_free_user_cannot_create_premium_generation(client: TestClient) -> None:
    response = client.post(
        "/api/generations",
        headers=user_headers(USER_A),
        json=generation_body(style="anime", quality="hd"),
    )
    assert response.status_code == 403
    assert response.json() == {
        "error": {
            "code": "PREMIUM_REQUIRED",
            "message": "This option requires a Premium subscription",
        }
    }


def test_premium_rejection_does_not_store_generation(client: TestClient) -> None:
    headers = user_headers(USER_A)
    client.post("/api/generations", headers=headers, json=generation_body(style="cinematic"))
    history = client.get("/api/generations", headers=headers)
    assert history.status_code == 200
    assert history.json() == {"generations": []}


def test_premium_user_can_use_premium_options(client: TestClient) -> None:
    headers = user_headers(USER_A)
    client.post("/api/subscription/purchase", headers=headers)
    response = client.post(
        "/api/generations",
        headers=headers,
        json=generation_body(style="cinematic", aspect_ratio="16:9", quality="hd"),
    )
    assert response.status_code == 201
    assert response.json()["status"] == "pending"


def test_blank_prompt_returns_400(client: TestClient) -> None:
    response = client.post(
        "/api/generations",
        headers=user_headers(USER_A),
        json=generation_body(prompt="   "),
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_REQUEST"
    assert response.json()["error"]["message"] == "Prompt is required"


def test_unknown_option_returns_400(client: TestClient) -> None:
    response = client.post(
        "/api/generations",
        headers=user_headers(USER_A),
        json=generation_body(style="oil-painting"),
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_REQUEST"


def test_trigger_error_finishes_as_failed(client: TestClient, clock: ManualClock) -> None:
    headers = user_headers(USER_A)
    created = client.post(
        "/api/generations",
        headers=headers,
        json=generation_body(prompt="trigger-error"),
    ).json()
    clock.moment = clock.moment + timedelta(seconds=4)
    first = client.get(f"/api/generations/{created['id']}", headers=headers)
    second = client.get(f"/api/generations/{created['id']}", headers=headers)
    history = client.get("/api/generations", headers=headers)
    assert first.status_code == 200
    assert first.json()["status"] == "failed"
    assert first.json()["error"]["code"] == "GENERATION_FAILED"
    assert second.json() == first.json()
    assert history.json()["generations"][0]["imageUrl"] is None
    assert history.json()["generations"][0]["error"]["code"] == "GENERATION_FAILED"


def test_successful_generation_returns_png(client: TestClient, clock: ManualClock, settings: Settings) -> None:
    headers = user_headers(USER_A)
    created = client.post("/api/generations", headers=headers, json=generation_body(style="photorealistic"))
    assert created.status_code == 201
    clock.moment = clock.moment + timedelta(seconds=4)
    status = client.get(f"/api/generations/{created.json()['id']}", headers=headers)
    image = client.get(status.json()["imageUrl"], headers=headers)
    expected = (settings.assets_dir / "photorealistic.png").read_bytes()
    assert status.status_code == 200
    assert status.json()["status"] == "completed"
    assert image.status_code == 200
    assert image.headers["content-type"].startswith("image/png")
    assert image.content == expected


def test_user_cannot_read_another_users_generation(client: TestClient) -> None:
    created = client.post("/api/generations", headers=user_headers(USER_A), json=generation_body()).json()
    response = client.get(f"/api/generations/{created['id']}", headers=user_headers(USER_B))
    missing = client.get(
        "/api/generations/11111111-1111-1111-1111-111111111111",
        headers=user_headers(USER_A),
    )
    assert response.status_code == 404
    assert response.json() == {"error": {"code": "NOT_FOUND", "message": "Generation not found"}}
    assert missing.json() == response.json()


def test_user_cannot_download_another_users_image(
    client: TestClient,
    clock: ManualClock,
) -> None:
    headers = user_headers(USER_A)
    created = client.post("/api/generations", headers=headers, json=generation_body()).json()
    clock.moment = clock.moment + timedelta(seconds=4)
    client.get(f"/api/generations/{created['id']}", headers=headers)
    response = client.get(f"/static/generated/{created['id']}.png", headers=user_headers(USER_B))
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


def test_history_returns_only_current_user(client: TestClient, clock: ManualClock) -> None:
    client.post("/api/generations", headers=user_headers(USER_A), json=generation_body(prompt="mine"))
    clock.moment = clock.moment + timedelta(seconds=1)
    client.post("/api/generations", headers=user_headers(USER_B), json=generation_body(prompt="theirs"))
    history = client.get("/api/generations", headers=user_headers(USER_A))
    assert history.status_code == 200
    assert [item["prompt"] for item in history.json()["generations"]] == ["mine"]
    assert history.json()["generations"][0]["status"] == "processing"
    assert history.json()["generations"][0]["imageUrl"] is None
    assert history.json()["generations"][0]["error"] is None
    assert history.json()["generations"][0]["createdAt"] == "2026-11-02T08:00:00Z"


def test_completed_generation_stays_stable(client: TestClient, clock: ManualClock, settings: Settings) -> None:
    headers = user_headers(USER_A)
    created = client.post("/api/generations", headers=headers, json=generation_body()).json()
    clock.moment = clock.moment + timedelta(seconds=4)
    first = client.get(f"/api/generations/{created['id']}", headers=headers)
    image_path = settings.images_dir / f"{created['id']}.png"
    modified_at = image_path.stat().st_mtime_ns
    second = client.get(f"/api/generations/{created['id']}", headers=headers)
    assert first.status_code == 200
    assert second.json() == first.json()
    assert image_path.stat().st_mtime_ns == modified_at


def test_ready_generation_completes_after_restart(
    settings: Settings,
    clock: ManualClock,
) -> None:
    first_app = create_app(settings, clock)
    with TestClient(first_app) as first_client:
        created = first_client.post(
            "/api/generations",
            headers=user_headers(USER_A),
            json=generation_body(style="digital-art"),
        ).json()
    clock.moment = clock.moment + timedelta(seconds=4)
    second_app = create_app(settings, clock)
    with TestClient(second_app) as second_client:
        response = second_client.get(
            f"/api/generations/{created['id']}",
            headers=user_headers(USER_A),
        )
    assert response.status_code == 200
    assert response.json()["status"] == "completed"
    assert response.json()["imageUrl"] == f"/static/generated/{created['id']}.png"


def test_missing_and_invalid_user_id(client: TestClient) -> None:
    missing = client.get("/api/subscription")
    invalid = client.get("/api/subscription", headers=user_headers("nope"))
    assert missing.status_code == 400
    assert missing.json()["error"]["code"] == "USER_ID_REQUIRED"
    assert invalid.status_code == 400
    assert invalid.json()["error"]["code"] == "INVALID_USER_ID"


def test_history_completes_overdue_generation(client: TestClient, clock: ManualClock) -> None:
    headers = user_headers(USER_A)
    created = client.post("/api/generations", headers=headers, json=generation_body()).json()
    clock.moment = clock.moment + timedelta(seconds=4)
    history = client.get("/api/generations", headers=headers)
    item = history.json()["generations"][0]
    assert item["id"] == created["id"]
    assert item["status"] == "completed"
    assert item["imageUrl"] == f"/static/generated/{created['id']}.png"
    assert item["error"] is None


def test_unfinished_image_is_hidden(client: TestClient) -> None:
    headers = user_headers(USER_A)
    created = client.post("/api/generations", headers=headers, json=generation_body()).json()
    response = client.get(f"/static/generated/{created['id']}.png", headers=headers)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"
