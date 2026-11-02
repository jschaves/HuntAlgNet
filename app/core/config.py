from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    app_name: str = "HuntAlgNet"
    environment: str = "production"
    api_prefix: str = "/api/v1"
    debug: bool = False
    enable_docs: bool = False
    trusted_hosts: str = ""

    secret_key: str = "dev-insecure-secret-change-me-please-use-48-bytes-min"
    access_token_expire_minutes: int = 1440
    oauth_state_expire_minutes: int = 15

    database_url: str = (
        "postgresql+psycopg://huntalgnet:change-me@localhost:5432/huntalgnet"
    )
    redis_url: str = "redis://localhost:6379/0"

    fernet_key: str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    google_client_id: str = ""
    google_client_secret: str = ""
    google_redirect_uri: str = (
        "http://localhost:8000/api/v1/integrations/youtube/callback"
    )
    youtube_scopes: str = (
        "https://www.googleapis.com/auth/youtube.readonly "
        "https://www.googleapis.com/auth/yt-analytics.readonly "
        "https://www.googleapis.com/auth/youtube.upload"
    )

    frontend_url: str = "http://localhost:3000"
    cors_origins: str = "http://localhost:3000"

    ollama_base_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "llama3.2:3b"

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def trusted_host_list(self) -> list[str]:
        return [host.strip() for host in self.trusted_hosts.split(",") if host.strip()]

    @property
    def youtube_scope_list(self) -> list[str]:
        return [scope for scope in self.youtube_scopes.replace(",", " ").split() if scope]


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
