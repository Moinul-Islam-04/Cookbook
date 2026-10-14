"""Validate and normalize uploaded photos, and sign short-lived read URLs for them.

Uploads are decoded (not trusted by extension or Content-Type), re-encoded to JPEG with
no metadata, so GPS and other EXIF never reach storage, and capped in size and pixels.
"""

import hashlib
import hmac
import io
import time
from dataclasses import dataclass

from PIL import Image, ImageOps, UnidentifiedImageError

MAX_UPLOAD_BYTES = 10 * 1024 * 1024
MAX_SOURCE_PIXELS = 50_000_000  # rejects decompression bombs before decoding
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}
FULL_EDGE = 2048
THUMB_EDGE = 600
JPEG_QUALITY = 85


class InvalidImage(ValueError):
    pass


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
            img = ImageOps.exif_transpose(img)  # bake in rotation before EXIF is dropped
            img = img.convert("RGB")
            full = _jpeg(img, FULL_EDGE)
            thumb = _jpeg(img, THUMB_EDGE)
            width, height = Image.open(io.BytesIO(full)).size
    except InvalidImage:
        raise
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError, Image.DecompressionBombError):
        raise InvalidImage("That file isn't a readable image.") from None
    return ProcessedImage(full=full, thumb=thumb, width=width, height=height)


def _jpeg(img: Image.Image, edge: int) -> bytes:
    copy = img.copy()
    copy.thumbnail((edge, edge), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    copy.save(out, "JPEG", quality=JPEG_QUALITY, optimize=True)  # no exif= → no metadata
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
