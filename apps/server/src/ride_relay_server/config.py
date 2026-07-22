from __future__ import annotations

import base64
from functools import lru_cache

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="RIDE_RELAY_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    environment: str = "production"
    database_url: str = "postgresql+psycopg://ride_relay@db/ride_relay"
    data_encryption_key: SecretStr
    cursor_signing_key: SecretStr
    trusted_hosts: list[str] = Field(default_factory=lambda: ["*"])
    forwarded_allow_ips: str = "127.0.0.1"
    auto_create_schema: bool = False
    ride_retention_hours: int = Field(default=72, ge=24, le=24 * 30)
    ended_ride_grace_hours: int = Field(default=24, ge=1, le=72)
    idempotency_retention_hours: int = Field(default=24, ge=1, le=72)
    rate_limit_requests: int = Field(default=600, ge=10, le=100_000)
    rate_limit_window_seconds: int = Field(default=60, ge=1, le=3600)
    join_code_lookup_rate_limit_requests: int = Field(default=30, ge=1, le=1000)
    join_code_lookup_rate_limit_window_seconds: int = Field(default=60, ge=1, le=3600)
    join_code_global_rate_limit_requests: int = Field(default=20, ge=1, le=1000)
    discovery_suggestion_rate_limit_requests: int = Field(default=10, ge=1, le=1000)
    discovery_suggestion_rate_limit_window_seconds: int = Field(
        default=3600,
        ge=60,
        le=24 * 3600,
    )
    discovery_admin_token: SecretStr | None = None
    discovery_admin_name: str = Field(default="discovery-admin", min_length=1, max_length=120)
    discovery_rejected_retention_days: int = Field(default=90, ge=7, le=365)
    discovery_allowed_origins: list[str] = Field(
        default_factory=lambda: [
            "https://tailendcharlie.app",
            "https://www.tailendcharlie.app",
        ]
    )
    maximum_request_bytes: int = Field(default=64 * 1024, ge=1024, le=1024 * 1024)
    maximum_response_bytes: int = Field(default=128 * 1024, ge=4096, le=2 * 1024 * 1024)
    maximum_event_bytes: int = Field(default=8 * 1024, ge=1024, le=64 * 1024)
    maximum_upload_events: int = Field(default=20, ge=1, le=100)
    maximum_download_events: int = Field(default=100, ge=1, le=500)
    maximum_active_rides: int = Field(default=100, ge=1, le=100_000)
    maximum_events_per_ride: int = Field(default=5_000, ge=100, le=100_000)
    maximum_stored_bytes_per_ride: int = Field(
        default=25 * 1024 * 1024,
        ge=1024 * 1024,
        le=1024 * 1024 * 1024,
    )
    maximum_replays_per_ride: int = Field(default=5_000, ge=1, le=100_000)
    maximum_replay_bytes_per_ride: int = Field(
        default=25 * 1024 * 1024,
        ge=1024 * 1024,
        le=1024 * 1024 * 1024,
    )
    plan_retention_days: int = Field(default=30, ge=1, le=365)
    maximum_plan_bytes: int = Field(
        default=11 * 1024 * 1024,
        ge=1024 * 1024,
        le=32 * 1024 * 1024,
    )
    maximum_plan_points: int = Field(default=200_000, ge=100, le=1_000_000)
    plan_create_rate_limit_requests: int = Field(default=10, ge=1, le=1000)
    plan_create_rate_limit_window_seconds: int = Field(default=3600, ge=1, le=86400)
    plan_lookup_rate_limit_requests: int = Field(default=30, ge=1, le=1000)
    plan_lookup_rate_limit_window_seconds: int = Field(default=60, ge=1, le=3600)

    @field_validator("data_encryption_key", "cursor_signing_key")
    @classmethod
    def validate_key(cls, value: SecretStr) -> SecretStr:
        raw = value.get_secret_value()
        try:
            decoded = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
        except (ValueError, TypeError) as error:
            raise ValueError("must be a base64url-encoded 32-byte key") from error
        if len(decoded) != 32:
            raise ValueError("must decode to exactly 32 bytes")
        return value

    @field_validator("discovery_admin_token", mode="before")
    @classmethod
    def validate_discovery_admin_token(
        cls,
        value: object,
    ) -> object:
        if value is None or value == "":
            return None
        raw_value = value.get_secret_value() if isinstance(value, SecretStr) else str(value)
        if len(raw_value) < 32:
            raise ValueError("must contain at least 32 characters when configured")
        return value

    def decoded_key(self, field: str) -> bytes:
        value = getattr(self, field).get_secret_value()
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
