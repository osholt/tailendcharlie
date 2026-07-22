from __future__ import annotations

import base64
import hashlib
import hmac
import json
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from ride_relay_server.app import create_app
from ride_relay_server.config import Settings


def _key(byte: int) -> str:
    return base64.urlsafe_b64encode(bytes([byte]) * 32).decode().rstrip("=")


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        environment="test",
        database_url=f"sqlite:///{tmp_path / 'relay.db'}",
        data_encryption_key=_key(7),
        cursor_signing_key=_key(11),
        trusted_hosts=["testserver"],
        auto_create_schema=True,
        rate_limit_requests=600,
    )


@pytest.fixture
def client(settings: Settings):
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def ride_token(ride_id: str, secret: str) -> str:
    digest = hmac.new(
        secret.encode(),
        f"ride-relay-internet-token-v1\n{ride_id}".encode(),
        hashlib.sha256,
    ).digest()
    return "rr1_" + base64.urlsafe_b64encode(digest).decode().rstrip("=")


def event(
    ride_id: str,
    event_id: str,
    *,
    device_id: str = "device-a",
    event_type: str = "rideCreated",
    payload: dict[str, Any] | None = None,
    expires_at: datetime | None = None,
    created_at: datetime | None = None,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "id": event_id,
        "rideId": ride_id,
        "deviceId": device_id,
        "type": event_type,
        "priority": "routine",
        "createdAt": (created_at or datetime.now(UTC)).isoformat().replace("+00:00", "Z"),
        "expiresAt": expires_at.isoformat().replace("+00:00", "Z") if expires_at else None,
        "payload": payload or {},
        "signature": "a" * 64,
        "acknowledged": False,
    }


def sync_request(
    client: TestClient,
    *,
    ride_id: str,
    secret: str,
    device_id: str = "device-a",
    cursor: str | None = None,
    events: list[dict[str, Any]] | None = None,
    token: str | None = None,
    client_protocol: int | None = None,
    capabilities: list[str] | None = None,
    platform: str | None = None,
):
    body = json.dumps(
        {
            "protocolVersion": 1,
            "deviceId": device_id,
            "cursor": cursor,
            "events": events or [],
        },
        separators=(",", ":"),
    ).encode()
    digest = base64.urlsafe_b64encode(hashlib.sha256(body).digest()).decode().rstrip("=")
    headers = {
        "authorization": f"Bearer {token or ride_token(ride_id, secret)}",
        "content-type": "application/json",
        "idempotency-key": f"rr1-{digest}",
        "x-ride-relay-device": device_id,
    }
    if client_protocol is not None:
        headers["x-tailendcharlie-protocol"] = str(client_protocol)
    if capabilities is not None:
        headers["x-tailendcharlie-capabilities"] = ",".join(capabilities)
    if platform is not None:
        headers["x-tailendcharlie-platform"] = platform
    return client.post(
        f"/api/v1/rides/{ride_id}/events:sync",
        content=body,
        headers=headers,
    )


@pytest.fixture
def make_event() -> Callable[..., dict[str, Any]]:
    return event


@pytest.fixture
def synchronize() -> Callable[..., Any]:
    return sync_request
