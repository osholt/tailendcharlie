"""Synthetic-only collector tests. No provider HTTP or real station records."""

import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import collector as c


def location(ident="one"):
    return {
        "id": ident,
        "country_code": "GB",
        "party_id": "TST",
        "country": "GBR",
        "name": "Synthetic charger",
        "coordinates": {"latitude": "51", "longitude": "-1"},
        "evses": [
            {
                "status": "AVAILABLE",
                "connectors": [
                    {
                        "standard": "IEC_62196_T2_COMBO",
                        "max_electric_power": 50000,
                        "tariff_ids": ["test-price"],
                    }
                ],
            }
        ],
    }


def tariff():
    return {
        "id": "test-price",
        "country_code": "GB",
        "party_id": "TST",
        "currency": "GBP",
        "elements": [{"price_components": [{"type": "ENERGY", "price": 0.5, "vat": 20}]}],
    }


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.store = c.Store(":memory:")
        self.addCleanup(self.store.db.close)
        self.feed = {
            "id": "test",
            "name": "Test",
            "locations_url": "https://example.com/locations",
            "auth": "none",
            "credential_env": "",
        }

    def view(self, now=100):
        return self.store.viewport(-1.1, 50.9, -0.9, 51.1, now)

    def test_join_prices_with_explicit_vat_and_namespace(self):
        self.store.ingest(self.feed, "locations", [location()], 1, 100, True)
        self.store.ingest(self.feed, "tariffs", [tariff()], 1, 100, True)
        conn = self.view()["locations"][0]["connectors"][0]
        self.assertEqual(conn["pencePerKwh"], 60)
        self.assertEqual(conn["status"], "AVAILABLE")
        self.assertEqual(conn["type"], 2)
        self.assertEqual(conn["kilowatts"], 50)
        other = dict(self.feed, id="other")
        self.store.ingest(other, "locations", [location()], 1, 100, True)
        self.assertNotIn("pencePerKwh", self.view()["locations"][0]["connectors"][0])

    def test_complex_unknown_vat_expired_and_non_gbp_tariffs_are_not_prices(self):
        cases = []
        t = tariff()
        t["elements"][0]["price_components"][0].pop("vat")
        cases.append(t)
        t = tariff()
        t["elements"][0]["restrictions"] = {"start_time": "09:00"}
        cases.append(t)
        t = tariff()
        t["elements"][0]["price_components"].append({"type": "FLAT", "price": 1})
        cases.append(t)
        t = tariff()
        t["currency"] = "EUR"
        cases.append(t)
        t = tariff()
        t["end_date_time"] = "1970-01-01T00:00:10Z"
        cases.append(t)
        for t in cases:
            self.assertIsNone(c.simple_tariff(t, 100))

    def test_embedded_tariff_is_connector_local_and_expires(self):
        for wrapped in [False, True]:
            row = location()
            conn = row["evses"][0]["connectors"][0]
            t = tariff()
            t["end_date_time"] = "1970-01-01T00:03:20Z"
            conn["tariffs"] = [t] if wrapped else t
            row["evses"][0]["connectors"].append(dict(location()["evses"][0]["connectors"][0]))
            self.store.ingest(self.feed, "locations", [row], 1, 100, True)
            connectors = self.view()["locations"][0]["connectors"]
            self.assertEqual(connectors[0]["pencePerKwh"], 60)
            self.assertEqual(connectors[0]["priceCheckedAt"], 100)
            self.assertNotIn("embeddedPrice", connectors[0])
            self.assertNotIn("pencePerKwh", connectors[1])
            self.assertNotIn("pencePerKwh", self.view(200)["locations"][0]["connectors"][0])
        row = location()
        row["evses"][0]["connectors"][0]["tariffs"] = tariff()
        self.store.ingest(self.feed, "locations", [row], 1, 100, True)
        self.assertNotIn("pencePerKwh", self.view(86501)["locations"][0]["connectors"][0])

    def test_invalid_embedded_tariffs_never_fall_back_to_separate_price(self):
        self.store.ingest(self.feed, "tariffs", [tariff()], 1, 100, True)
        cases = [
            None,
            [],
            [tariff(), tariff()],
            "invalid",
            {},
            dict(tariff(), id="different"),
            dict(tariff(), party_id="OTHER"),
            dict(tariff(), currency="EUR"),
            dict(tariff(), elements=None),
            dict(tariff(), elements=[{"price_components": None}]),
            dict(tariff(), elements=[{"price_components": [{"type": "ENERGY", "price": 0.5}]}]),
            dict(tariff(), end_date_time="1970-01-01T00:00:10Z"),
        ]
        for value in cases:
            with self.subTest(value=value):
                row = location()
                row["evses"][0]["connectors"][0]["tariffs"] = value
                self.store.ingest(self.feed, "locations", [row], 1, 100, True)
                conn = self.view()["locations"][0]["connectors"][0]
                self.assertNotIn("pencePerKwh", conn)
                self.assertNotIn("embeddedPrice", conn)

    def test_bad_coordinates_private_non_uk_removed_and_unknown_status(self):
        for mutation in [
            {"publish": False},
            {"country": "USA"},
            {"coordinates": {"latitude": "nan"}},
        ]:
            self.assertIsNone(c.normalize(dict(location(), **mutation), "test", 100))
        row = location()
        row["evses"][0]["status"] = "REMOVED"
        self.assertEqual(c.normalize(row, "test", 100)["connectors"], [])
        row["evses"][0]["status"] = "FAKE"
        self.assertEqual(c.normalize(row, "test", 100)["connectors"][0]["status"], "UNKNOWN")

    def test_partial_sweep_preserves_old_rows_complete_sweep_removes_them(self):
        self.store.ingest(self.feed, "locations", [location("old")], 1, 100, True)
        self.store.ingest(self.feed, "locations", [location("new")], 2, 110, False)
        self.assertEqual(len(self.view(110)["locations"]), 2)
        self.assertFalse(self.view(110)["sources"][0]["complete"])
        self.store.ingest(self.feed, "locations", [], 2, 120, True)
        self.assertEqual(len(self.view(120)["locations"]), 1)
        self.assertTrue(self.view(120)["sources"][0]["complete"])
        self.assertEqual(self.view(200000)["locations"], [])

    def test_viewport_limits_and_truncation(self):
        for args in [(-2, 50, 0, 51), (0, 0, 0, 0), (float("nan"), 0, 1, 1)]:
            with self.assertRaises(ValueError):
                self.store.viewport(*args, 100)
        self.store.ingest(
            self.feed, "locations", [location(str(i)) for i in range(305)], 1, 100, True
        )
        view = self.view()
        self.assertEqual(len(view["locations"]), 300)
        self.assertTrue(view["truncated"])

    def test_scheduler_origin_spacing_and_incremental_pages(self):
        fetch = Mock(return_value=(200, [location(str(i)) for i in range(100)], 101))
        other = dict(self.feed, id="other")
        collector = c.Collector(
            self.store, [self.feed, other], [{"id": "test"}, {"id": "other"}], {}, fetch
        )
        self.assertTrue(collector.step(100))
        self.assertFalse(collector.step(101))
        self.assertTrue(collector.step(225))
        self.assertEqual(fetch.call_count, 2)
        self.assertFalse(collector.step(226))
        fetch.return_value = (200, [location("last")], 101)
        self.assertTrue(collector.step(350))
        self.assertIn("offset=100", fetch.call_args.args[0])
        self.assertEqual(len(self.view(350)["locations"]), 201)

    def test_response_shapes_select_only_their_own_record_list(self):
        rows = [location()]
        self.assertEqual(c.rows_from({"status_code": 1000, "data": rows}, "ocpi"), rows)
        self.assertIsNone(c.rows_from({"status_code": 2001, "data": rows}, "ocpi"))
        self.assertEqual(c.rows_from(rows, "array"), rows)
        self.assertIsNone(c.rows_from({"data": rows}, "array"))
        self.assertIsNone(c.rows_from(rows, "ocpi"))
        self.assertEqual(c.rows_from({"locations": rows, "tariffs": []}, "locations-key"), rows)
        self.assertIsNone(c.rows_from({"data": rows}, "locations-key"))
        self.assertIsNone(c.rows_from(rows, "locations-key"))

    def test_unpaged_feed_is_one_bounded_request_and_a_complete_sweep(self):
        f = dict(self.feed, pagination="none", response_shape="array")
        self.store.ingest(f, "locations", [location("gone")], 1, 50, True)
        fetch = Mock(return_value=(200, [location(str(i)) for i in range(237)], None))
        collector = c.Collector(self.store, [f], [{"id": "test"}], {}, fetch)
        self.assertTrue(collector.step(100))
        self.assertEqual(fetch.call_args.args[0], "https://example.com/locations")
        self.assertEqual(fetch.call_args.args[2], "array")
        ids = {loc["id"] for loc in self.view(100)["locations"]}
        self.assertEqual(len(ids), 237)
        self.assertNotIn("gone", ids)
        self.assertEqual(collector.jobs[0]["offset"], 0)
        self.assertGreaterEqual(collector.jobs[0]["due"], 700)

    def test_paged_feed_still_rejects_a_page_larger_than_requested(self):
        fetch = Mock(return_value=(200, [location(str(i)) for i in range(101)], None))
        collector = c.Collector(self.store, [self.feed], [{"id": "test"}], {}, fetch)
        collector.step(100)
        self.assertEqual(self.view()["sources"][0]["outcome"], "fetch-failed")
        self.assertEqual(self.view()["locations"], [])

    def test_unknown_response_shape_is_a_configuration_error(self):
        f = dict(self.feed, response_shape="guess")
        collector = c.Collector(self.store, [f], [{"id": "test"}], {}, Mock())
        with self.assertRaises(ValueError):
            collector.step(100)

    def test_rate_limit_backoff_and_failure_does_not_block_another_origin(self):
        other = dict(self.feed, id="other", locations_url="https://other.example/locations")
        fetch = Mock(side_effect=[(429, None, None), (200, [location()], 1)])
        collector = c.Collector(
            self.store, [self.feed, other], [{"id": "test"}, {"id": "other"}], {}, fetch
        )
        collector.step(100)
        collector.step(101)
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(collector.jobs[0]["due"], 3700)
        self.assertEqual(self.view(101)["locations"][0]["source"], "other")

    def test_missing_credentials_skip_without_anonymous_probe(self):
        f = dict(self.feed, auth="token", credential_env="OCPI_FEED_TEST_TOKEN")
        fetch = Mock()
        collector = c.Collector(self.store, [f], [{"id": "test"}], {}, fetch)
        collector.step(100)
        fetch.assert_not_called()
        self.assertEqual(self.view()["sources"][0]["outcome"], "credentials-missing")

    def test_partial_dual_credentials_do_not_block_other_sources(self):
        f = dict(
            self.feed,
            auth="token",
            credential_env="TOKEN",
            api_key_env="KEY",
            auth_header="Authorization",
            auth_scheme="Token",
        )
        other = dict(self.feed, id="other", locations_url="https://other.example/locations")
        fetch = Mock(return_value=(200, [location()], 1))
        collector = c.Collector(
            self.store,
            [f, other],
            [{"id": "test"}, {"id": "other"}],
            {"TOKEN": "synthetic-token"},
            fetch,
        )
        collector.step(100)
        self.assertEqual(fetch.call_count, 1)
        self.assertTrue(fetch.call_args.args[0].startswith("https://other.example/"))
        self.assertEqual(collector.jobs[0]["due"], 3700)
        outcomes = {s["id"]: s["outcome"] for s in self.view()["sources"]}
        self.assertEqual(outcomes["test"], "credential-configuration")

    def test_stale_or_expired_price_is_removed_without_losing_location(self):
        self.store.ingest(self.feed, "locations", [location()], 1, 100, True)
        self.store.ingest(self.feed, "tariffs", [tariff()], 1, 100, True)
        self.assertNotIn("pencePerKwh", self.view(90000)["locations"][0]["connectors"][0])


if __name__ == "__main__":
    unittest.main()
