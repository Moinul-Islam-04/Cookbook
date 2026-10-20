"""Validate and normalize uploaded photos, and sign short-lived read URLs for them.

Uploads are decoded (not trusted by extension or Content-Type), re-encoded to JPEG with
no metadata, so GPS and other EXIF never reach storage, and capped in size and pixels.
"""

import hashlib
import hmac
import io
import math
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

from PIL import Image, ImageOps, UnidentifiedImageError

MAX_UPLOAD_BYTES = 10 * 1024 * 1024
# Rejects decompression bombs before decoding. The phone sends at most 2048 px (~4 MP);
# 24 MP still fits a full-resolution camera photo from another client.
MAX_SOURCE_PIXELS = 24_000_000
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}
FULL_EDGE = 2048
THUMB_EDGE = 600
JPEG_QUALITY = 85
# One decode at a time, so concurrent uploads can't stack their full-size buffers in the
# server's 1 GB. Waiting uploads hold a thread and their spooled request body, not pixels.
PROCESSING_WAIT_S = 20.0
_processing = threading.Semaphore(1)


class InvalidImage(ValueError):
    pass


class ProcessingBusy(Exception):
    """Another upload held the processing slot for longer than PROCESSING_WAIT_S."""


@contextmanager
def processing_slot() -> Iterator[None]:
    if not _processing.acquire(timeout=PROCESSING_WAIT_S):
        raise ProcessingBusy()
    try:
        yield
    finally:
        _processing.release()


@dataclass(frozen=True)
class ProcessedImage:
    full: bytes
    thumb: bytes
    width: int
    height: int


def process_upload(data: bytes) -> ProcessedImage:
    if not data:
        raise InvalidImage("The file is empty.")
    if len(data) > MAX_UPLOAD_BYTES:
        raise InvalidImage(f"Photos must be {MAX_UPLOAD_BYTES // (1024 * 1024)} MB or smaller.")
    try:
        with Image.open(io.BytesIO(data)) as probe:
            fmt = probe.format
            if fmt not in ALLOWED_FORMATS:
                raise InvalidImage("Upload a JPEG, PNG or WebP photo.")
            if probe.width * probe.height > MAX_SOURCE_PIXELS:
                raise InvalidImage("That image is too large.")
            probe.verify()  # structural check; the image must be reopened afterwards
        with Image.open(io.BytesIO(data)) as img:
            if fmt == "JPEG":
                _decode_at_reduced_size(img, FULL_EDGE)
            ImageOps.exif_transpose(img, in_place=True)  # bake in rotation before EXIF is dropped
            if img.mode != "RGB":
                img = img.convert("RGB")
            img.thumbnail((FULL_EDGE, FULL_EDGE), Image.Resampling.LANCZOS)
            width, height = img.size
            full = _jpeg(img)
            # From the 2048 px result, not the original: no second full-size pass.
            img.thumbnail((THUMB_EDGE, THUMB_EDGE), Image.Resampling.LANCZOS)
            thumb = _jpeg(img)
    except InvalidImage:
        raise
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError, Image.DecompressionBombError):
        raise InvalidImage("That file isn't a readable image.") from None
    return ProcessedImage(full=full, thumb=thumb, width=width, height=height)


def _decode_at_reduced_size(img: Image.Image, edge: int) -> None:
    """Ask the JPEG decoder to scale by 1/2, 1/4 or 1/8 while decoding, as long as the long
    edge stays at least `edge`: a 24 MP photo then decodes to 6 MP, not 24.

    The scale is uniform, so EXIF rotation applied afterwards is unaffected.
    """
    w, h = img.size
    if max(w, h) <= edge:
        return
    r = edge / max(w, h)
    img.draft("RGB", (max(1, math.ceil(w * r)), max(1, math.ceil(h * r))))


def _jpeg(img: Image.Image) -> bytes:
    out = io.BytesIO()
    img.save(out, "JPEG", quality=JPEG_QUALITY, optimize=True)  # no exif= → no metadata
    return out.getvalue()


# ---- signed read URLs ----


def _signature(secret: str, key: str, expires: int) -> str:
    return hmac.new(secret.encode(), f"{key}\n{expires}".encode(), hashlib.sha256).hexdigest()


def signed_path(secret: str, key: str, ttl_s: int, now: float | None = None) -> tuple[str, int]:
    """A relative URL that reads `key` until it expires, plus the expiry (unix seconds).

    Expiry is rounded up to the next TTL boundary so repeated loads within a window
    produce the same URL and hit the client's cache.
    """
    now = now if now is not None else time.time()
    expires = int(now // ttl_s + 2) * ttl_s
    return f"/v1/image-files/{key}?exp={expires}&sig={_signature(secret, key, expires)}", expires


def verify_signature(secret: str, key: str, expires: int, sig: str, now: float | None = None) -> bool:
    now = now if now is not None else time.time()
    return expires > now and hmac.compare_digest(_signature(secret, key, expires), sig)


class ImageSigner:
    def __init__(self, secret: str, ttl_s: int) -> None:
        self.secret = secret
        self.ttl_s = ttl_s

    def sign(self, key: str) -> tuple[str, int]:
        return signed_path(self.secret, key, self.ttl_s)

    def verify(self, key: str, expires: int, sig: str) -> bool:
        return verify_signature(self.secret, key, expires, sig)
