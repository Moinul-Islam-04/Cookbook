import uuid
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict

# The owner: the single local user. In "dev" mode every request is this user; in "token"
# mode `python -m app.tokens create` issues device tokens for this user by default.
DEV_USER_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="COOKBOOK_", env_file=".env", extra="ignore")

    database_url: str = "postgresql+psycopg://localhost:5432/cookbook"
    # "dev": no authentication, every request is the owner (127.0.0.1 only).
    # "token": every request needs `Authorization: Bearer <device token>`.
    auth_mode: str = "dev"
    # Which extraction provider turns captions into drafts: "fake" (rule-based, no model)
    # or "ollama" (a local model).
    extraction_provider: str = "fake"
    # A local 7B model on a 16 GB M2 took ~60 s on a real 1,000-character reel caption.
    extraction_timeout_s: float = 120.0
    # Photos: "s3" (MinIO on this Mac; R2/S3 later) or "memory" (tests).
    storage_backend: str = "memory"
    s3_endpoint_url: str = "http://127.0.0.1:9000"
    s3_bucket: str = "cookbook-images"
    s3_access_key: str = ""
    s3_secret_key: str = ""
    s3_region: str = "us-east-1"
    # HMAC key for signed photo URLs. Empty: a random key per process (URLs die on restart).
    image_signing_key: str = ""
    image_url_ttl_s: int = 600
    max_images_per_recipe: int = 10
    ollama_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "qwen2.5:7b"
    draft_ttl_hours: int = 24


@lru_cache
def get_settings() -> Settings:
    return Settings()
