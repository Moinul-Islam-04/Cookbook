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
    # Google sign-in: comma-separated OAuth client IDs whose ID tokens we accept (the iOS
    # client's ID). Empty: POST /v1/auth/google is turned off.
    google_client_ids: str = ""
    # Which extraction provider turns captions into drafts: "fake" (rule-based, no model) or
    # "anthropic" (Claude over the API: captions go to Anthropic and each import costs money).
    extraction_provider: str = "fake"
    # Claude Haiku usually answers in a few seconds; this is the ceiling before a 504.
    extraction_timeout_s: float = 120.0
    # Photos: "s3" (AWS S3 on the server) or "memory" (tests and local development; photos
    # are lost when the process restarts).
    storage_backend: str = "memory"
    s3_endpoint_url: str = "https://s3.us-east-2.amazonaws.com"
    s3_bucket: str = "cookbook-images"
    s3_access_key: str = ""
    s3_secret_key: str = ""
    s3_region: str = "us-east-1"
    # HMAC key for signed photo URLs. Empty: a random key per process (URLs die on restart).
    image_signing_key: str = ""
    image_url_ttl_s: int = 600
    max_images_per_recipe: int = 10
    anthropic_api_key: str = ""
    anthropic_model: str = "claude-haiku-5-5"
    draft_ttl_hours: int = 24


@lru_cache
def get_settings() -> Settings:
    return Settings()
