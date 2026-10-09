from __future__ import annotations

import base64

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from ride_relay_server.app import create_app
from ride_relay_server.config import Settings

SECRET = "0123456789abcdef0123456789abcdef"


def _key(byte: int) -> str:
    return base64.urlsafe_b64encode(bytes([byte]) * 32).decode().rstrip("=")


CURRENT_CAPABILITIES = [
    "global-ride-heatmap-v1",
    "ride-start-v1",
    "live-presence-v2",
    "membership-v1",
    "observer-access-v1",
    "pre-start-presence-v1",
    "push-notifications-v1",
    "rejoin-route-sharing-v1",
    "ride-reopen-v1",
    "rider-contact-sharing-v1",
    "road-ratings-v1",
    "route-revisions-v1",
    "tec-role-assignment-v1",
    "traffic-incidents-v1",
    "traffic-reroutes-v1",
]


def test_compatibility_document_advertises_protocol_and_capabilities(client) -> None:
    response = client.get("/api/v1/compatibility")

    assert response.status_code == 200
    assert response.json() == {
        "serverBuildCommit": "unknown",
        "serverProtocol": 1,
        "minimumClientProtocol": 1,
        "maximumClientProtocol": 1,
        "capabilities": sorted(CURRENT_CAPABILITIES),
        "requiredCapabilities": [],
        "cacheSeconds": 300,
        "updateUrls": {
            "default": "https://tailendcharlie.app",
            "iOS": "https://tailendcharlie.app",
            "android": "https://tailendcharlie.app",
        },
        "serviceUrls": {},
    }


def test_compatibility_document_reports_deployed_commit(settings) -> None:
    settings.build_commit = "a2b4537595869ccd1530c77c3f2e72fe63389f41"
    with TestClient(create_app(settings)) as client:
        response = client.get("/api/v1/compatibility")

    assert response.status_code == 200
    assert response.json()["serverBuildCommit"] == settings.build_commit


def test_compatibility_document_advertises_configured_service_urls(settings) -> None:
    settings = settings.model_copy(
        update={
            "service_valhalla_url": "https://routing.example.com/valhalla",
            "service_photon_url": "https://routing.example.com/photon",
        }
    )
    with TestClient(create_app(settings)) as client:
        response = client.get("/api/v1/compatibility")

    assert response.status_code == 200
    # Only what is configured: a client keeps its own fallback for the rest.
    assert response.json()["serviceUrls"] == {
        "valhalla": "https://routing.example.com/valhalla",
        "photon": "https://routing.example.com/photon",
    }


def test_service_urls_are_normalised_and_blank_means_unset(tmp_path) -> None:
    settings = Settings(
        data_encryption_key=_key(7),
        cursor_signing_key=_key(11),
        database_url=f"sqlite:///{tmp_path / 'relay.sqlite3'}",
        service_valhalla_url=" https://routing.example.com/valhalla/ ",
        service_osrm_url="   ",
    )

    assert settings.service_urls == {"valhalla": "https://routing.example.com/valhalla"}


@pytest.mark.parametrize(
    "url",
    [
        "http://routing.example.com/valhalla",
        "https://user:secret@routing.example.com/valhalla",
        "https://user@routing.example.com/valhalla",
        "https://routing.example.com/valhalla?key=1",
        "https://routing.example.com/valhalla#x",
        "https:///valhalla",
        "routing.example.com/valhalla",
    ],
)
def test_service_urls_refuse_anything_but_a_plain_https_base(tmp_path, url) -> None:
    with pytest.raises(ValidationError):
        Settings(
            data_encryption_key=_key(7),
            cursor_signing_key=_key(11),
            database_url=f"sqlite:///{tmp_path / 'relay.sqlite3'}",
            service_photon_url=url,
        )


def test_sync_rejects_client_below_minimum_protocol(client, settings, synchronize) -> None:
    client.app.state.settings.minimum_client_protocol = 2

    response = synchronize(
        client,
        ride_id="ride-old-client",
        secret=SECRET,
        client_protocol=1,
        platform="iOS",
    )

    assert response.status_code == 426
    assert response.json()["code"] == "update_required"
    assert response.json()["updateUrl"] == settings.ios_update_url


def test_sync_rejects_client_newer_than_server(client, synchronize) -> None:
    response = synchronize(
        client,
        ride_id="ride-new-client",
        secret=SECRET,
        client_protocol=2,
    )

    assert response.status_code == 409
    assert response.json() == {
        "code": "server_upgrade_required",
        "message": "This app is newer than the configured ride service.",
        "serverProtocol": 1,
    }


def test_sync_rejects_missing_required_capability(settings, synchronize) -> None:
    settings.required_capabilities = ["membership-v1"]
    with TestClient(create_app(settings)) as client:
        response = synchronize(
            client,
            ride_id="ride-missing-capability",
            secret=SECRET,
            client_protocol=1,
            capabilities=["ride-start-v1"],
        )

    assert response.status_code == 426
    assert response.json()["code"] == "update_required"
    assert response.json()["requiredCapabilities"] == ["membership-v1"]


def test_current_client_protocol_and_capabilities_synchronize(client, synchronize) -> None:
    response = synchronize(
        client,
        ride_id="ride-current-client",
        secret=SECRET,
        client_protocol=1,
        capabilities=CURRENT_CAPABILITIES,
    )

    assert response.status_code == 200


def test_join_code_lookup_rejects_an_old_client_before_resolution(client, settings) -> None:
    settings.minimum_client_protocol = 2

    response = client.get(
        "/api/v1/join-codes/123456",
        headers={
            "x-tailendcharlie-protocol": "1",
            "x-tailendcharlie-platform": "android",
        },
    )

    assert response.status_code == 426
    assert response.json()["code"] == "update_required"
    assert response.json()["updateUrl"] == settings.android_update_url
