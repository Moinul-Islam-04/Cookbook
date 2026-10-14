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
    ollama_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "qwen2.5:7b"
    draft_ttl_hours: int = 24


@lru_cache
def get_settings() -> Settings:
    return Settings()
