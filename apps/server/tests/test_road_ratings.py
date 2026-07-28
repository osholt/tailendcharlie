"""Anonymous rider road ratings (#159)."""

from __future__ import annotations

from contextlib import contextmanager

from fastapi.testclient import TestClient
from pydantic import SecretStr

from ride_relay_server.app import create_app
from ride_relay_server.discovery import road_rating_recommendation

ROAD = "osm-good-biking-road-0006a6641990bc7c"
SOURCE = "derived/osm-good-biking-road-0006a6641990bc7c"
CATALOGUE = "uk-osm-2026-07-23-v1"


@contextmanager
def _admin_client(settings):
    configured = settings.model_copy(
        update={
            "discovery_admin_token": SecretStr("admin-token-at-least-32-characters"),
            "discovery_admin_name": "test-reviewer",
        }
    )
    with TestClient(create_app(configured)) as client:
        yield client


def _rating(verdict: str = "worth_including", **overrides) -> dict:
    payload = {
        "featureId": ROAD,
        "sourceFeatureId": SOURCE,
        "category": "good_biking_road",
        "verdict": verdict,
        "catalogueVersion": CATALOGUE,
    }
    payload.update(overrides)
    return payload


def _submit(client, count: int = 1, verdict: str = "worth_including") -> None:
    for _ in range(count):
        response = client.post("/api/v1/discovery/road-ratings", json=_rating(verdict))
        assert response.status_code == 204, response.text


def test_rating_is_accepted_without_any_credential(client):
    response = client.post("/api/v1/discovery/road-ratings", json=_rating())

    assert response.status_code == 204
    # No body, so there is no server-assigned identifier for a caller to be
    # correlated by on a later request.
    assert response.content == b""


def test_relay_rejects_any_field_that_could_identify_a_rider(client):
    for extra in (
        {"riderId": "rider-a"},
        {"deviceId": "device-a"},
        {"rideId": "ride-a"},
        {"installationId": "install-a"},
        {"createdAt": "2026-07-27T12:00:00Z"},
        {"latitude": 52.01},
    ):
        response = client.post(
            "/api/v1/discovery/road-ratings",
            json=_rating(**extra),
        )
        assert response.status_code == 400, extra


def test_ratings_are_tallied_not_logged_per_submission(settings):
    with _admin_client(settings) as client:
        _submit(client, count=4, verdict="worth_including")
        _submit(client, count=1, verdict="not_worth_including")

        report = client.get(
            "/api/v1/admin/discovery/road-ratings",
            headers={"authorization": "Bearer admin-token-at-least-32-characters"},
        )

    assert report.status_code == 200
    body = report.json()
    assert body["thresholds"] == {
        "minimumResponses": 5,
        "promotionShare": 0.7,
        "reviewShare": 0.6,
    }
    assert len(body["ratings"]) == 1
    entry = body["ratings"][0]
    assert entry["featureId"] == ROAD
    assert entry["sourceFeatureId"] == SOURCE
    assert entry["catalogueVersion"] == CATALOGUE
    assert entry["worthIncluding"] == 4
    assert entry["notWorthIncluding"] == 1
    # Day granularity only: a receipt second could be lined up against the ride
    # journal's own sequence.
    assert entry["firstRatedOn"] == entry["lastRatedOn"]
    assert len(entry["firstRatedOn"]) == len("2026-07-28")
    assert entry["recommendation"] == "promote"


def test_a_single_dislike_recommends_nothing(settings):
    with _admin_client(settings) as client:
        _submit(client, count=1, verdict="not_worth_including")

        report = client.get(
            "/api/v1/admin/discovery/road-ratings",
            headers={"authorization": "Bearer admin-token-at-least-32-characters"},
        )

    entry = report.json()["ratings"][0]
    assert entry["notWorthIncluding"] == 1
    assert entry["recommendation"] == "insufficient"


def test_a_disliked_road_is_only_ever_flagged_for_a_human(settings):
    with _admin_client(settings) as client:
        _submit(client, count=5, verdict="not_worth_including")

        report = client.get(
            "/api/v1/admin/discovery/road-ratings",
            headers={"authorization": "Bearer admin-token-at-least-32-characters"},
        )

    assert report.json()["ratings"][0]["recommendation"] == "review-for-removal"


def test_ratings_for_a_different_catalogue_release_are_counted_separately(settings):
    with _admin_client(settings) as client:
        _submit(client, count=3)
        response = client.post(
            "/api/v1/discovery/road-ratings",
            json=_rating(catalogueVersion="uk-osm-2026-09-01-v1"),
        )
        assert response.status_code == 204

        report = client.get(
            "/api/v1/admin/discovery/road-ratings",
            headers={"authorization": "Bearer admin-token-at-least-32-characters"},
        )

    versions = {entry["catalogueVersion"] for entry in report.json()["ratings"]}
    assert versions == {CATALOGUE, "uk-osm-2026-09-01-v1"}


def test_rating_report_requires_the_administrator_credential(settings):
    with _admin_client(settings) as client:
        unauthenticated = client.get("/api/v1/admin/discovery/road-ratings")
        wrong = client.get(
            "/api/v1/admin/discovery/road-ratings",
            headers={"authorization": "Bearer not-the-configured-admin-token"},
        )

    assert unauthenticated.status_code == 401
    assert wrong.status_code == 401


def test_rating_submissions_are_rate_limited(settings):
    limited = settings.model_copy(
        update={"discovery_rating_rate_limit_requests": 2},
    )
    with TestClient(create_app(limited)) as client:
        assert client.post("/api/v1/discovery/road-ratings", json=_rating()).status_code == 204
        assert client.post("/api/v1/discovery/road-ratings", json=_rating()).status_code == 204
        throttled = client.post("/api/v1/discovery/road-ratings", json=_rating())

    assert throttled.status_code == 429
    assert "retry-after" in throttled.headers


def test_unknown_verdict_or_category_is_refused(client):
    assert (
        client.post(
            "/api/v1/discovery/road-ratings",
            json=_rating(verdict="five_stars"),
        ).status_code
        == 400
    )
    assert (
        client.post(
            "/api/v1/discovery/road-ratings",
            json=_rating(category="racetrack"),
        ).status_code
        == 400
    )


def test_road_ratings_capability_is_advertised(client):
    response = client.get("/api/v1/compatibility")

    assert response.status_code == 200
    assert "road-ratings-v1" in response.json()["capabilities"]


def test_aggregation_rule_thresholds():
    # Below the minimum, nothing is recommended however one-sided.
    assert road_rating_recommendation(4, 0) == "insufficient"
    assert road_rating_recommendation(0, 4) == "insufficient"
    # 70% positive promotes; 5 of 7 is 71%, 4 of 6 is 67%.
    assert road_rating_recommendation(5, 2) == "promote"
    assert road_rating_recommendation(4, 2) == "insufficient"
    # 60% negative flags for review.
    assert road_rating_recommendation(2, 3) == "review-for-removal"
    assert road_rating_recommendation(3, 3) == "insufficient"
