"""Application settings loaded from environment variables (12-factor)."""

from functools import lru_cache

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CF_", env_file=".env", extra="ignore")

    app_name: str = "cloudforge-api"
    environment: str = "local"
    log_level: str = "INFO"
    version: str = Field(default="dev", validation_alias=AliasChoices("APP_VERSION", "CF_VERSION"))

    db_host: str = "postgres"
    db_port: int = 5432
    db_name: str = "cloudforge"
    db_user: str = "cloudforge"
    db_password: str = ""  # injected from Kubernetes Secret / .env, never baked in
    db_pool_size: int = 10
    db_max_overflow: int = 5
    database_url_override: str | None = None

    redis_host: str = "redis"
    redis_port: int = 6379
    redis_password: str | None = None
    redis_db: int = 0
    cache_ttl_seconds: int = 60

    cors_origins: list[str] = ["*"]

    @property
    def database_url(self) -> str:
        if self.database_url_override:
            return self.database_url_override
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
