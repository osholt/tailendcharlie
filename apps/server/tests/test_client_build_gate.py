"""The per-platform minimum app build gate (#37).

Covers the pure decision, the compatibility document, the structured 426 on every
entry point that already enforces the protocol gate, and the combinations that
matter for a staged rollout: gate off (the default), an old client the gate
retires, a client at exactly the minimum, and clients that cannot be judged.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from ride_relay_server.app import create_app
from ride_relay_server.client_build_gate import (
    minimum_builds,
    parse_client_build,
    unmet_minimum_build,
)
from ride_relay_server.config import Settings

from .conftest import ride_token

SECRET = "0123456789abcdef0123456789abcdef"


@pytest.fixture
def gated_client(settings: Settings):
    settings.minimum_client_build_ios = 103
    settings.minimum_client_build_android = 100
    with TestClient(create_app(settings)) as test_client:
        yield test_client


# -- the pure decision --------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("103", 103), (" 103 ", 103), ("1", 1), ("2100000000", 2_100_000_000)],
)
def test_parse_client_build_reads_a_plain_integer(raw: str, expected: int) -> None:
    assert parse_client_build(raw) == expected


@pytest.mark.parametrize("raw", [None, "", "  ", "unknown", "0", "0103", "1.0.1+22", "-4", "10a"])
def test_parse_client_build_refuses_anything_else(raw: str | None) -> None:
    assert parse_client_build(raw) is None


def test_minimum_builds_omits_platforms_whose_gate_is_off() -> None:
    assert minimum_builds(ios=0, android=0) == {}
    assert minimum_builds(ios=103, android=0) == {"iOS": 103}
    assert minimum_builds(ios=0, android=90) == {"android": 90}
    assert minimum_builds(ios=103, android=90) == {"iOS": 103, "android": 90}


def test_unmet_minimum_build_judges_only_a_readable_build_below_its_platform_minimum() -> None:
    minimums = {"iOS": 103, "android": 100}

    assert unmet_minimum_build("iOS", "102", minimums) == 103
    assert unmet_minimum_build("iOS", "103", minimums) is None
    assert unmet_minimum_build("iOS", "104", minimums) is None
    assert unmet_minimum_build("android", "99", minimums) == 100
    assert unmet_minimum_build("android", "100", minimums) is None


def test_unmet_minimum_build_fails_open_on_what_it_cannot_judge() -> None:
    minimums = {"iOS": 103, "android": 100}

    # A platform with no configured minimum, and clients that are not store builds.
    assert unmet_minimum_build("iOS", "50", {"android": 100}) is None
    assert unmet_minimum_build("", "50", minimums) is None
    assert unmet_minimum_build("web", "50", minimums) is None
    # Builds that cannot be read as a number: unstamped local builds and noise.
    assert unmet_minimum_build("iOS", "unknown", minimums) is None
    assert unmet_minimum_build("iOS", None, minimums) is None
    assert unmet_minimum_build("iOS", "1.0.1+22", minimums) is None


# -- configuration ------------------------------------------------------------


def test_the_gate_is_off_by_default(settings: Settings) -> None:
    assert settings.minimum_client_build_ios == 0
    assert settings.minimum_client_build_android == 0


def test_minimums_are_read_from_the_environment(
    settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("RIDE_RELAY_MINIMUM_CLIENT_BUILD_IOS", "103")
    monkeypatch.setenv("RIDE_RELAY_MINIMUM_CLIENT_BUILD_ANDROID", "100")

    loaded = Settings(
        data_encryption_key=settings.data_encryption_key,
        cursor_signing_key=settings.cursor_signing_key,
    )

    assert loaded.minimum_client_build_ios == 103
    assert loaded.minimum_client_build_android == 100


def test_a_negative_minimum_is_rejected(settings: Settings) -> None:
    with pytest.raises(ValidationError):
        Settings(**settings.model_dump(mode="python") | {"minimum_client_build_android": -1})


# -- the compatibility document -----------------------------------------------


def test_compatibility_document_lists_only_the_gated_platforms(settings: Settings) -> None:
    settings.minimum_client_build_ios = 103
    with TestClient(create_app(settings)) as client:
        body = client.get("/api/v1/compatibility").json()

    assert body["minimumClientBuilds"] == {"iOS": 103}


def test_compatibility_document_is_valid_for_a_client_that_ignores_the_new_field(
    gated_client,
) -> None:
    body = gated_client.get("/api/v1/compatibility").json()

    # Every field a build that predates the gate reads is still present.
    for field in (
        "serverProtocol",
        "minimumClientProtocol",
        "maximumClientProtocol",
        "capabilities",
        "requiredCapabilities",
        "cacheSeconds",
        "updateUrls",
    ):
        assert field in body
    assert body["minimumClientBuilds"] == {"iOS": 103, "android": 100}


# -- the gate on every entry point --------------------------------------------


def test_gate_off_an_old_build_still_synchronizes(client, synchronize) -> None:
    response = synchronize(
        client,
        ride_id="ride-gate-off",
        secret=SECRET,
        platform="iOS",
        app_build="1",
    )

    assert response.status_code == 200


def test_sync_refuses_a_build_below_the_minimum_with_the_fields_old_clients_read(
    gated_client, settings, synchronize
) -> None:
    response = synchronize(
        gated_client,
        ride_id="ride-old-build",
        secret=SECRET,
        platform="iOS",
        app_build="102",
    )

    assert response.status_code == 426
    body = response.json()
    # `code`, `message` and `updateUrl` are exactly what every shipped client
    # parses from a 426, so an old build can show the link without an update.
    assert body["code"] == "update_required"
    assert "no longer supported" in body["message"]
    assert body["updateUrl"] == settings.ios_update_url
    assert body["minimumClientBuild"] == 103


def test_the_minimum_itself_is_accepted_and_one_below_is_not(gated_client, synchronize) -> None:
    at_minimum = synchronize(
        gated_client, ride_id="ride-at-min", secret=SECRET, platform="iOS", app_build="103"
    )
    below = synchronize(
        gated_client, ride_id="ride-below-min", secret=SECRET, platform="iOS", app_build="102"
    )

    assert at_minimum.status_code == 200
    assert below.status_code == 426


def test_a_refused_sync_accepts_no_ride_state(gated_client, synchronize, make_event) -> None:
    ride_id = "ride-refused-state"
    refused = synchronize(
        gated_client,
        ride_id=ride_id,
        secret=SECRET,
        events=[make_event(ride_id, "evt-from-old-build")],
        platform="android",
        app_build="99",
    )
    current = synchronize(
        gated_client,
        ride_id=ride_id,
        device_id="device-b",
        secret=SECRET,
        platform="android",
        app_build="100",
    )

    assert refused.status_code == 426
    assert current.status_code == 200
    assert current.json()["events"] == []


def test_each_platform_is_judged_against_its_own_minimum(gated_client, synchronize) -> None:
    # 101 is below iOS 103 but at or above android 100.
    android = synchronize(
        gated_client, ride_id="ride-android", secret=SECRET, platform="android", app_build="101"
    )
    ios = synchronize(
        gated_client, ride_id="ride-ios", secret=SECRET, platform="iOS", app_build="101"
    )

    assert android.status_code == 200
    assert ios.status_code == 426
    assert ios.json()["code"] == "update_required"


@pytest.mark.parametrize(
    ("platform", "app_build"),
    [
        (None, "1"),  # no platform: curl, a monitor, the web watcher
        ("web", "1"),
        ("iOS", "unknown"),  # an unstamped local build
        ("iOS", None),  # no build header at all
        ("iOS", "1.0.1+22"),
    ],
)
def test_a_client_that_cannot_be_judged_is_not_refused(
    gated_client, synchronize, platform: str | None, app_build: str | None
) -> None:
    response = synchronize(
        gated_client,
        ride_id="ride-unjudged",
        secret=SECRET,
        platform=platform,
        app_build=app_build,
    )

    assert response.status_code == 200


def test_join_code_lookup_and_registration_are_refused_before_anything_is_read(
    gated_client, settings
) -> None:
    ride_id = "ride-join-gate"
    old_build = {"x-tailendcharlie-platform": "android", "x-tailendcharlie-app-build": "99"}
    current_build = {"x-tailendcharlie-platform": "android", "x-tailendcharlie-app-build": "100"}
    body = {
        "rideId": ride_id,
        "inviteSecret": SECRET,
        "resolveToken": "resolve-token-0123456789abcdef",
    }
    auth = {"authorization": f"Bearer {ride_token(ride_id, SECRET)}"}

    registration = gated_client.put(
        "/api/v1/join-codes/123456", json=body, headers={**old_build, **auth}
    )
    lookup = gated_client.get("/api/v1/join-codes/123456", headers=old_build)

    for response in (registration, lookup):
        assert response.status_code == 426
        assert response.json()["code"] == "update_required"
        assert response.json()["updateUrl"] == settings.android_update_url
    # The refused registration stored nothing: a current build finds no such code.
    assert gated_client.get("/api/v1/join-codes/123456", headers=current_build).status_code == 404


def test_a_build_gate_never_hides_the_protocol_gate_beneath_it(gated_client, synchronize) -> None:
    gated_client.app.state.settings.minimum_client_protocol = 2

    response = synchronize(
        gated_client,
        ride_id="ride-both-gates",
        secret=SECRET,
        client_protocol=1,
        platform="iOS",
        app_build="500",
    )

    assert response.status_code == 426
    assert "minimumClientProtocol" in response.json()


def test_every_refusal_is_counted_by_reason_and_platform(gated_client, synchronize) -> None:
    synchronize(gated_client, ride_id="ride-metric", secret=SECRET, platform="iOS", app_build="102")

    metrics = gated_client.get("/metrics").text

    assert 'ride_relay_client_update_required_total{platform="iOS",reason="build"} 1.0' in metrics
