"""Milestone 4 photos: validation, privacy, signed reads, ownership, failures, cleanup."""

import io
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from PIL import Image, JpegImagePlugin
from sqlalchemy import Engine
from sqlalchemy.orm import Session

from app import images as app_images
from app.cleanup import cleanup_orphan_objects
from app.routers import images as images_router
from app.images import signed_path
from app.storage import MemoryStore
from tests.conftest import count, test_settings
from tests.test_recipes_api import assert_error, create


def image_bytes(fmt="JPEG", size=(800, 600), exif=None, color=(200, 80, 40)) -> bytes:
    out = io.BytesIO()
    img = Image.new("RGB", size, color)
    kwargs = {"exif": exif} if exif is not None else {}
    img.save(out, fmt, **kwargs)
    return out.getvalue()


def gps_exif(orientation: int | None = None) -> bytes:
    exif = Image.Exif()
    exif[0x8825] = {1: "N", 2: (40.0, 26.0, 46.0), 3: "W", 4: (79.0, 58.0, 56.0)}  # GPSInfo
    exif[0x010F] = "PhoneMaker"  # Make
    if orientation:
        exif[0x0112] = orientation
    return exif.tobytes()


def upload(client: TestClient, rid: str, data: bytes, name="photo.jpg", ctype="image/jpeg"):
    return client.post(f"/v1/recipes/{rid}/images", files={"file": (name, data, ctype)})


def store(app) -> MemoryStore:
    return app.state.store


def test_upload_returns_signed_urls_and_appears_on_recipe(app, client: TestClient) -> None:
    rid = create(client)["id"]
    res = upload(client, rid, image_bytes(size=(4000, 3000)))
    assert res.status_code == 201, res.text
    img = res.json()
    assert (img["width"], img["height"]) == (2048, 1536)  # capped to 2048 on the long edge
    assert img["url"].startswith("/v1/image-files/users/") and "sig=" in img["url"]
    full = client.get(img["url"])
    assert full.status_code == 200 and full.headers["content-type"] == "image/jpeg"
    assert Image.open(io.BytesIO(full.content)).size == (2048, 1536)
    thumb = Image.open(io.BytesIO(client.get(img["thumbnail_url"]).content))
    assert max(thumb.size) == 600
    detail = client.get(f"/v1/recipes/{rid}").json()
    assert [i["id"] for i in detail["images"]] == [img["id"]]
    listed = client.get("/v1/recipes").json()["items"][0]
    assert listed["thumbnail_url"] and listed["thumbnail_url"].split("?")[0] == img["thumbnail_url"].split("?")[0]


def test_png_and_webp_accepted_and_stored_as_jpeg(app, client: TestClient) -> None:
    rid = create(client)["id"]
    for fmt in ("PNG", "WEBP"):
        assert upload(client, rid, image_bytes(fmt), name=f"x.{fmt.lower()}").status_code == 201
    assert all(ct == "image/jpeg" for _, ct, _ in store(app).objects.values())


def test_gps_and_camera_metadata_are_stripped(app, client: TestClient) -> None:
    rid = create(client)["id"]
    original = image_bytes(exif=gps_exif())
    assert Image.open(io.BytesIO(original)).getexif().get(0x8825)  # the fixture really has GPS
    img = upload(client, rid, original).json()
    for url in (img["url"], img["thumbnail_url"]):
        stored = Image.open(io.BytesIO(client.get(url).content))
        assert len(stored.getexif()) == 0


def test_exif_rotation_is_applied_before_metadata_is_dropped(client: TestClient) -> None:
    rid = create(client)["id"]
    # Orientation 6 = rotate 90° clockwise to display: an 800x600 sensor image shows as 600x800.
    img = upload(client, rid, image_bytes(size=(800, 600), exif=gps_exif(orientation=6))).json()
    assert (img["width"], img["height"]) == (600, 800)


@pytest.mark.parametrize(
    "data, name, message",
    [
        (b"", "x.jpg", "empty"),
        (b"this is not an image, just text pretending", "x.jpg", "readable image"),
        (image_bytes("GIF"), "x.gif", "JPEG, PNG or WebP"),
        (image_bytes()[:200], "x.jpg", "readable image"),  # truncated upload
    ],
)
def test_invalid_files_are_rejected_and_nothing_is_stored(app, client: TestClient, engine: Engine, data, name, message) -> None:
    rid = create(client)["id"]
    body = assert_error(upload(client, rid, data, name=name), 422, "invalid_image")
    assert message in body["message"] and body["field_errors"][0]["field"] == "file"
    assert count(engine, "recipe_images") == 0 and store(app).objects == {}


def test_oversized_upload_is_rejected(app, client: TestClient) -> None:
    rid = create(client)["id"]
    huge = image_bytes() + b"\0" * (10 * 1024 * 1024)
    assert "10 MB" in assert_error(upload(client, rid, huge), 422, "invalid_image")["message"]
    assert store(app).objects == {}


def test_decompression_bomb_is_rejected(client: TestClient) -> None:
    rid = create(client)["id"]
    bomb = io.BytesIO()
    Image.new("L", (10_000, 10_000)).save(bomb, "PNG")  # tiny file, 100 MP when decoded
    assert len(bomb.getvalue()) < 1_000_000
    assert_error(upload(client, rid, bomb.getvalue(), name="b.png"), 422, "invalid_image")


def test_signature_tampering_and_expiry_are_refused(app, client: TestClient) -> None:
    rid = create(client)["id"]
    img = upload(client, rid, image_bytes()).json()
    path, query = img["url"].split("?")
    exp = int(query.split("exp=")[1].split("&")[0])
    assert_error(client.get(f"{path}?exp={exp}&sig={'0' * 64}"), 403, "invalid_signature")
    assert_error(client.get(f"{path}?exp={exp + 600}&{query.split('&')[1]}"), 403, "invalid_signature")
    # A signature for one key doesn't open another (here: the thumbnail's key).
    thumb_path = img["thumbnail_url"].split("?")[0]
    assert_error(client.get(f"{thumb_path}?{query}"), 403, "invalid_signature")
    signer = app.state.image_signer
    key = path.removeprefix("/v1/image-files/")
    expired, _ = signed_path(signer.secret, key, 60, now=time.time() - 3600)
    assert_error(client.get(expired), 403, "invalid_signature")


def test_deleting_a_photo_makes_it_unreadable_immediately(app, client: TestClient, engine: Engine) -> None:
    rid = create(client)["id"]
    img = upload(client, rid, image_bytes()).json()
    assert client.delete(f"/v1/recipes/{rid}/images/{img['id']}").status_code == 204
    assert_error(client.get(img["url"]), 404, "not_found")  # still within the URL's TTL
    assert count(engine, "recipe_images") == 0 and store(app).objects == {}
    assert_error(client.delete(f"/v1/recipes/{rid}/images/{img['id']}"), 404, "not_found")


def test_deleting_a_recipe_removes_its_photos(app, client: TestClient, engine: Engine) -> None:
    rid = create(client)["id"]
    img = upload(client, rid, image_bytes()).json()
    upload(client, rid, image_bytes(color=(0, 0, 255)))
    assert len(store(app).objects) == 4
    assert client.delete(f"/v1/recipes/{rid}").status_code == 204
    assert_error(client.get(img["url"]), 404, "not_found")
    assert count(engine, "recipe_images") == 0 and store(app).objects == {}


def test_positions_and_limit(app, client: TestClient) -> None:
    app.state.settings.max_images_per_recipe = 2
    rid = create(client)["id"]
    first = upload(client, rid, image_bytes()).json()
    second = upload(client, rid, image_bytes()).json()
    assert (first["position"], second["position"]) == (0, 1)
    assert_error(upload(client, rid, image_bytes()), 422, "too_many_images")
    # The rejected upload's objects were removed, not left behind.
    assert len(store(app).objects) == 4


def test_photos_are_owner_scoped(client: TestClient, make_user, act_as) -> None:
    rid = create(client)["id"]
    img = upload(client, rid, image_bytes()).json()
    act_as(make_user())
    assert_error(upload(client, rid, image_bytes()), 404, "not_found")
    assert_error(client.delete(f"/v1/recipes/{rid}/images/{img['id']}"), 404, "not_found")
    act_as(None)
    assert client.get(img["url"]).status_code == 200


def test_storage_outage_fails_cleanly(app, client: TestClient, engine: Engine) -> None:
    rid = create(client)["id"]
    img = upload(client, rid, image_bytes()).json()
    store(app).fail = True
    body = assert_error(upload(client, rid, image_bytes()), 503, "storage_unavailable")
    assert body["retryable"] is True
    assert count(engine, "recipe_images") == 1
    assert_error(client.get(img["url"]), 503, "storage_unavailable")
    # A failed object delete still removes the photo from the recipe (cleanup gets the rest).
    assert client.delete(f"/v1/recipes/{rid}/images/{img['id']}").status_code == 204
    store(app).fail = False
    assert_error(client.get(img["url"]), 404, "not_found")


def test_cleanup_removes_only_old_unreferenced_objects(app, client: TestClient, engine: Engine) -> None:
    rid = create(client)["id"]
    upload(client, rid, image_bytes())
    s = store(app)
    old = datetime.now(UTC) - timedelta(hours=2)
    s.objects["users/x/recipes/y/orphan.jpg"] = (b"x", "image/jpeg", old)
    s.objects["users/x/recipes/y/fresh.jpg"] = (b"x", "image/jpeg", datetime.now(UTC))
    with Session(engine) as session:
        assert cleanup_orphan_objects(session, s) == 1
    assert "users/x/recipes/y/orphan.jpg" not in s.objects
    assert "users/x/recipes/y/fresh.jpg" in s.objects  # might be an upload mid-commit
    assert len(s.objects) == 3  # the referenced photo + thumb survive


def test_in_token_mode_upload_needs_a_token_but_signed_reads_do_not(engine: Engine, make_user) -> None:
    from app.auth import issue_token
    from app.main import create_app
    from tests.conftest import test_settings

    app = create_app(test_settings(auth_mode="token"))
    with Session(engine) as s:
        _, token = issue_token(s, make_user(), "t")
        s.commit()
    h = {"Authorization": f"Bearer {token}"}
    with TestClient(app) as c:
        rid = c.post("/v1/recipes", json={"title": "x"}, headers=h).json()["id"]
        assert_error(upload(c, rid, image_bytes()), 401, "unauthenticated")
        img = c.post(f"/v1/recipes/{rid}/images", files={"file": ("p.jpg", image_bytes(), "image/jpeg")}, headers=h).json()
        assert c.get(img["url"]).status_code == 200  # AsyncImage can load it without a header


# ---- uploads don't block other requests, and decode one at a time ----


def slow_processing(monkeypatch, seconds: float, started: threading.Event | None = None) -> dict:
    """Make process_upload block like a large Pillow decode, and record its concurrency."""
    real = images_router.process_upload
    stats = {"running": 0, "max": 0}
    lock = threading.Lock()

    def slow(data: bytes):
        with lock:
            stats["running"] += 1
            stats["max"] = max(stats["max"], stats["running"])
        if started is not None:
            started.set()
        time.sleep(seconds)  # blocking on purpose, as Pillow is
        with lock:
            stats["running"] -= 1
        return real(data)

    monkeypatch.setattr(images_router, "process_upload", slow)
    return stats


def test_an_upload_in_progress_does_not_block_other_requests(monkeypatch, client: TestClient) -> None:
    rid = create(client)["id"]
    started = threading.Event()
    slow_processing(monkeypatch, 1.5, started)
    with ThreadPoolExecutor(1) as pool:
        pending = pool.submit(upload, client, rid, image_bytes())
        assert started.wait(5)
        t = time.perf_counter()
        assert client.get("/healthz").status_code == 200
        waited = time.perf_counter() - t
        assert pending.result().status_code == 201
    # Under the old `async def` this waited for the whole 1.5 s upload.
    assert waited < 0.5, f"/healthz waited {waited:.2f}s behind the upload"


def test_photos_are_processed_one_at_a_time(monkeypatch, app, client: TestClient) -> None:
    rid = create(client)["id"]
    stats = slow_processing(monkeypatch, 0.3)
    with ThreadPoolExecutor(3) as pool:
        results = list(pool.map(lambda _: upload(client, rid, image_bytes()), range(3)))
    assert [r.status_code for r in results] == [201, 201, 201]
    assert stats["max"] == 1


def test_upload_waiting_too_long_for_processing_gets_a_retryable_503(monkeypatch, app, client: TestClient) -> None:
    rid = create(client)["id"]
    monkeypatch.setattr(app_images, "PROCESSING_WAIT_S", 0.1)
    with app_images.processing_slot():  # another upload is being processed
        body = assert_error(upload(client, rid, image_bytes()), 503, "photo_processing_busy")
    assert body["retryable"] is True
    assert store(app).objects == {}
    assert upload(client, rid, image_bytes()).status_code == 201  # the slot was released


def test_more_than_24_megapixels_is_rejected(client: TestClient) -> None:
    rid = create(client)["id"]
    big = io.BytesIO()
    Image.new("L", (5000, 5000)).save(big, "PNG")  # 25 MP
    assert_error(upload(client, rid, big.getvalue(), name="b.png"), 422, "invalid_image")


def test_large_rotated_jpeg_is_decoded_reduced_and_comes_out_upright(monkeypatch, client: TestClient) -> None:
    drafted = []
    real_draft = JpegImagePlugin.JpegImageFile.draft

    def spy(self, mode, size):
        before = self.size
        result = real_draft(self, mode, size)
        drafted.append((before, self.size))
        return result

    monkeypatch.setattr(JpegImagePlugin.JpegImageFile, "draft", spy)
    # 6000x4000 sensor image, red top-left corner; orientation 6 = rotate 90° clockwise.
    sensor = Image.new("RGB", (6000, 4000), (255, 255, 255))
    sensor.paste((255, 0, 0), (0, 0, 1000, 1000))
    out = io.BytesIO()
    sensor.save(out, "JPEG", exif=gps_exif(orientation=6))
    rid = create(client)["id"]
    img = upload(client, rid, out.getvalue()).json()

    assert drafted[0] == ((6000, 4000), (3000, 2000))  # decoded at half size, not 24 MP
    assert (img["width"], img["height"]) == (1365, 2048)
    for url, edge in ((img["url"], 2048), (img["thumbnail_url"], 600)):
        stored = Image.open(io.BytesIO(client.get(url).content)).convert("RGB")
        assert max(stored.size) == edge and stored.width < stored.height
        # Rotated clockwise, the sensor's top-left corner is now the top-right.
        r, g, b = stored.getpixel((stored.width - 5, 5))
        assert r > 200 and g < 60 and b < 60
        r, g, b = stored.getpixel((5, 5))
        assert r > 200 and g > 200 and b > 200
        assert len(stored.getexif()) == 0
