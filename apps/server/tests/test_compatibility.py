from __future__ import annotations

from fastapi.testclient import TestClient

from ride_relay_server.app import create_app

SECRET = "0123456789abcdef0123456789abcdef"
CURRENT_CAPABILITIES = [
    "ride-start-v1",
    "membership-v1",
    "observer-access-v1",
    "pre-start-presence-v1",
    "push-notifications-v1",
    "route-revisions-v1",
]


def test_compatibility_document_advertises_protocol_and_capabilities(client) -> None:
    response = client.get("/api/v1/compatibility")

    assert response.status_code == 200
    assert response.json() == {
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
    }


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
