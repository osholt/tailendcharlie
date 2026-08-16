from __future__ import annotations

import base64
import hashlib
import hmac
import os
from datetime import UTC, date, datetime, timedelta

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from ride_relay_server.heatmap import cleanup_heatmap, rebuild_public_snapshot, tile_for_point
from ride_relay_server.models import (
    HeatmapContributor,
    HeatmapContributorCell,
    HeatmapSnapshot,
    HeatmapUploadReceipt,
)


def _credential(index: int) -> tuple[str, str, str]:
    handle = "hm1_" + base64.urlsafe_b64encode(bytes([index]) * 32).decode().rstrip("=")
    secret = "hms1_" + base64.urlsafe_b64encode(bytes([index + 20]) * 32).decode().rstrip("=")
    proof = "hmp1_" + base64.urlsafe_b64encode(
        hmac.new(
            secret.encode(),
            f"tail-end-charlie-heatmap-v1\n{handle}".encode(),
            hashlib.sha256,
        ).digest()
    ).decode().rstrip("=")
    return handle, secret, proof


def _register(client: TestClient, index: int) -> tuple[str, str]:
    handle, secret, proof = _credential(index)
    response = client.post(
        "/api/v1/heatmap/contributors",
        json={
            "schemaVersion": 1,
            "clientHandle": handle,
            "proof": proof,
            "consentVersion": "2026-08-v1",
        },
    )
    assert response.status_code == 201, response.text
    return handle, secret


def _contribute(
    client: TestClient,
    credential: tuple[str, str],
    *,
    upload: int,
    cells: list[tuple[int, int]],
):
    handle, secret = credential
    upload_id = "hmu1_" + base64.urlsafe_b64encode(upload.to_bytes(16, "big")).decode().rstrip("=")
    return client.post(
        "/api/v1/heatmap/contributions",
        headers={"authorization": f"Heatmap {handle}.{secret}"},
        json={
            "schemaVersion": 1,
            "uploadId": upload_id,
            "trimMetersAtEachEnd": 1000,
            "cells": [{"z": 17, "x": x, "y": y} for x, y in cells],
        },
    )


def test_sparse_coverage_is_suppressed_until_three_contributors(client: TestClient):
    cell = tile_for_point(51.46, -2.52, 17)
    for index in (1, 2):
        credential = _register(client, index)
        assert _contribute(client, credential, upload=index, cells=[cell]).status_code == 200

    response = client.get("/api/v1/heatmap/cells?west=-3&south=51&east=-2&north=52&zoom=17")
    assert response.status_code == 200
    assert response.json()["features"] == []


def test_public_snapshot_uses_buckets_and_never_exposes_identity(client: TestClient):
    cell = tile_for_point(51.46, -2.52, 17)
    for index in (1, 2, 3):
        credential = _register(client, index)
        assert _contribute(client, credential, upload=index, cells=[cell]).status_code == 200

    response = client.get("/api/v1/heatmap/cells?west=-3&south=51&east=-2&north=52&zoom=17")
    assert response.status_code == 200
    payload = response.json()
    assert payload["sparseCoverageHidden"] is True
    assert len(payload["features"]) == 1
    assert payload["features"][0]["properties"]["contributors"] == "3-4"
    encoded = response.text.lower()
    for forbidden in ("handle", "ride", "device", "timestamp", "speed"):
        assert forbidden not in encoded


def test_one_frequent_contributor_stays_suppressed_at_canonical_and_parent_zoom(
    client: TestClient,
):
    cell = tile_for_point(51.46, -2.52, 17)
    credential = _register(client, 1)
    for upload in range(1, 7):
        assert _contribute(client, credential, upload=upload, cells=[cell]).status_code == 200

    for zoom in (16, 17):
        response = client.get(
            f"/api/v1/heatmap/cells?west=-3&south=51&east=-2&north=52&zoom={zoom}"
        )
        assert response.status_code == 200
        assert response.json()["features"] == []


def test_parent_cell_reapplies_distinct_contributor_threshold(client: TestClient):
    canonical = tile_for_point(51.46, -2.52, 17)
    parent = canonical[0] >> 1, canonical[1] >> 1
    children = [
        (parent[0] * 2, parent[1] * 2),
        (parent[0] * 2 + 1, parent[1] * 2),
        (parent[0] * 2, parent[1] * 2 + 1),
    ]
    for index, child in enumerate(children, start=1):
        assert (
            _contribute(client, _register(client, index), upload=index, cells=[child]).status_code
            == 200
        )

    canonical_response = client.get(
        "/api/v1/heatmap/cells?west=-3&south=51&east=-2&north=52&zoom=17"
    )
    parent_response = client.get("/api/v1/heatmap/cells?west=-3&south=51&east=-2&north=52&zoom=16")
    assert canonical_response.json()["features"] == []
    assert len(parent_response.json()["features"]) == 1


def test_public_intensity_uses_coarse_bucket_boundaries(client: TestClient):
    cell = tile_for_point(51.46, -2.52, 17)
    first = _register(client, 1)
    for upload in range(1, 5):
        assert _contribute(client, first, upload=upload, cells=[cell]).status_code == 200
    for index in (2, 3):
        assert (
            _contribute(
                client,
                _register(client, index),
                upload=index + 10,
                cells=[cell],
            ).status_code
            == 200
        )

    payload = client.get("/api/v1/heatmap/cells?west=-3&south=51&east=-2&north=52&zoom=17").json()
    assert payload["features"][0]["properties"] == {
        "contributors": "3-4",
        "intensity": "medium",
        "weight": 0.5,
    }


def test_upload_is_idempotent_and_strictly_rejects_raw_track_fields(client: TestClient):
    credential = _register(client, 1)
    cell = tile_for_point(51.46, -2.52, 17)
    first = _contribute(client, credential, upload=1, cells=[cell])
    second = _contribute(client, credential, upload=1, cells=[cell])
    assert first.json()["duplicate"] is False
    assert second.json()["duplicate"] is True

    handle, secret = credential
    rejected = client.post(
        "/api/v1/heatmap/contributions",
        headers={"authorization": f"Heatmap {handle}.{secret}"},
        json={
            "schemaVersion": 1,
            "uploadId": "hmu1_" + base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip("="),
            "trimMetersAtEachEnd": 1000,
            "cells": [{"z": 17, "x": cell[0], "y": cell[1]}],
            "rawPolyline": [[-2.52, 51.46]],
            "rideId": "private-ride",
        },
    )
    assert rejected.status_code == 400


def test_revocation_invalidates_the_credential_and_cascades_private_rows(client: TestClient):
    cell = tile_for_point(51.46, -2.52, 17)
    credentials = [_register(client, index) for index in (1, 2, 3)]
    for index, registered in enumerate(credentials, start=1):
        assert _contribute(client, registered, upload=index, cells=[cell]).status_code == 200
    assert (
        len(
            client.get("/api/v1/heatmap/cells?west=-3&south=51&east=-2&north=52&zoom=17").json()[
                "features"
            ]
        )
        == 1
    )
    credential = credentials[0]
    handle, secret = credential

    removed = client.delete(
        "/api/v1/heatmap/contributors/current",
        headers={"authorization": f"Heatmap {handle}.{secret}"},
    )
    assert removed.status_code == 200
    assert removed.json()["removed"] is True
    denied = _contribute(client, credential, upload=2, cells=[cell])
    assert denied.status_code == 401
    with client.app.state.session_factory() as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(HeatmapContributorCell)
                .where(HeatmapContributorCell.handle_hash == _handle_hash(handle))
            )
            == 0
        )
        assert (
            session.scalar(
                select(func.count())
                .select_from(HeatmapUploadReceipt)
                .where(HeatmapUploadReceipt.handle_hash == _handle_hash(handle))
            )
            == 0
        )
        rebuild_public_snapshot(
            session,
            today=datetime.now(UTC).date() + timedelta(days=1),
        )
        assert session.scalar(select(func.count()).select_from(HeatmapSnapshot)) == 1
    assert (
        client.get("/api/v1/heatmap/cells?west=-3&south=51&east=-2&north=52&zoom=17").json()[
            "features"
        ]
        == []
    )


def _handle_hash(handle: str) -> bytes:
    return hashlib.sha256(handle.encode()).digest()


def test_cleanup_enforces_receipt_cell_and_orphan_retention(client: TestClient):
    old_credential = _register(client, 1)
    orphan_handle, _ = _register(client, 2)
    cell = tile_for_point(51.46, -2.52, 17)
    assert _contribute(client, old_credential, upload=1, cells=[cell]).status_code == 200
    today = date(2026, 8, 16)
    with client.app.state.session_factory() as session:
        old = session.scalar(select(HeatmapContributorCell))
        assert old is not None
        old.receipt_month = date(2024, 7, 1)
        receipt = session.scalar(select(HeatmapUploadReceipt))
        assert receipt is not None
        receipt.delete_after = today
        orphan = session.get(HeatmapContributor, _handle_hash(orphan_handle))
        assert orphan is not None
        orphan.last_seen_on = today - timedelta(days=91)
        session.commit()
        assert cleanup_heatmap(session, today=today) == (1, 1, 1)
        assert session.scalar(select(func.count()).select_from(HeatmapContributorCell)) == 0
        assert session.scalar(select(func.count()).select_from(HeatmapUploadReceipt)) == 0


def test_daily_upload_quota_is_enforced(client: TestClient):
    client.app.state.settings.heatmap_maximum_uploads_per_day = 1
    credential = _register(client, 1)
    cell = tile_for_point(51.46, -2.52, 17)
    assert _contribute(client, credential, upload=1, cells=[cell]).status_code == 200
    assert _contribute(client, credential, upload=2, cells=[cell]).status_code == 429


def test_bounds_authentication_and_cell_region_are_enforced(client: TestClient):
    outside = tile_for_point(40, -2, 17)
    credential = _register(client, 1)
    assert _contribute(client, credential, upload=1, cells=[outside]).status_code == 400
    assert (
        client.get("/api/v1/heatmap/cells?west=-10&south=49&east=3&north=61&zoom=6").status_code
        == 400
    )
    assert (
        client.post(
            "/api/v1/heatmap/contributions",
            headers={"authorization": "Heatmap invalid"},
            json={
                "schemaVersion": 1,
                "uploadId": "hmu1_" + base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip("="),
                "trimMetersAtEachEnd": 1000,
                "cells": [{"z": 17, "x": 1, "y": 1}],
            },
        ).status_code
        == 401
    )


def test_oversized_payload_is_rejected_before_storage(client: TestClient):
    credential = _register(client, 1)
    handle, secret = credential
    response = client.post(
        "/api/v1/heatmap/contributions",
        headers={
            "authorization": f"Heatmap {handle}.{secret}",
            "content-type": "application/json",
            "content-length": str(256 * 1024 + 1),
        },
        content=b"{}",
    )
    assert response.status_code == 413

    chunked = client.post(
        "/api/v1/heatmap/contributions",
        headers={
            "authorization": f"Heatmap {handle}.{secret}",
            "content-type": "application/json",
        },
        content=(part for part in (b"{" + b" " * (256 * 1024), b"}")),
    )
    assert chunked.status_code == 413


def test_compatibility_advertises_global_heatmap(client: TestClient):
    assert "global-ride-heatmap-v1" in client.get("/api/v1/compatibility").json()["capabilities"]
