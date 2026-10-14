import uuid
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict

# The single local-development user. Only used while auth_mode == "dev".
DEV_USER_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="COOKBOOK_", env_file=".env", extra="ignore")

    database_url: str = "postgresql+psycopg://localhost:5432/cookbook"
    auth_mode: str = "dev"
    # Which extraction provider turns captions into drafts. Only "fake" exists so far.
    extraction_provider: str = "fake"
    extraction_timeout_s: float = 20.0
    draft_ttl_hours: int = 24


@lru_cache
def get_settings() -> Settings:
    return Settings()
