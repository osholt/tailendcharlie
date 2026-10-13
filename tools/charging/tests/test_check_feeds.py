"""Offline tests: HTTP is mocked; CI never contacts a charge-point operator."""

import base64
import io
import json
import sys
import tomllib
import unittest
from contextlib import redirect_stdout
from http.client import IncompleteRead
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_feeds as checker


class Response(io.BytesIO):
    def __init__(self, body, headers=None, status=200):
        super().__init__(body if isinstance(body, bytes) else json.dumps(body).encode())
        self.headers = headers or {}
        self.status = status
        self.bytes_read = 0

    def read1(self, size):
        data = super().read1(size)
        self.bytes_read += len(data)
        return data


def feed(**changes):
    return {
        "id": "sample",
        "auth": "none",
        "credential_env": "",
        "versions_url": "https://feed.example/versions",
        "locations_url": "https://feed.example/locations",
        "check_result": "not-published",
        **changes,
    }


def location():
    # Entirely fictitious fixture; no real address, coordinate or identifier.
    return {
        "data": [
            {
                "id": "synthetic",
                "coordinates": {},
                "evses": [
                    {
                        "status": "AVAILABLE",
                        "connectors": [{"tariff_ids": ["synthetic-tariff"]}],
                    }
                ],
            }
        ],
        "status_code": 1000,
    }


class ProbeTests(unittest.TestCase):
    def test_tariffs_only_uses_one_small_request_without_location_claim(self):
        opener = Mock()
        opener.open.return_value = Response(self.tariff())
        result = checker.probe(
            feed(tariffs_url="https://feed.example/tariffs"), {}, opener, tariffs_only=True
        )
        self.assertEqual(opener.open.call_count, 1)
        self.assertEqual(
            opener.open.call_args.args[0].full_url, "https://feed.example/tariffs?limit=1"
        )
        self.assertEqual(result["tariffs"], "observed")
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(result["reason"], "one-tariff-observed-not-location-matched")

    @staticmethod
    def tariff(price=0.5):
        return {
            "data": [
                {
                    "id": "synthetic",
                    "currency": "GBP",
                    "elements": [{"price_components": [{"type": "ENERGY", "price": price}]}],
                }
            ]
        }

    def test_tariff_requires_finite_nonnegative_numeric_energy_price(self):
        for value in [True, "0.5", None, -1, float("nan"), float("inf")]:
            with self.subTest(value=value):
                self.assertEqual(checker.tariff_features(self.tariff(value)), "not-observed")
        self.assertEqual(checker.tariff_features(self.tariff(0)), "observed")

    def test_tariff_page_requires_one_object_currency_and_structure(self):
        for body in [
            location(),
            {"data": []},
            {"data": self.tariff()["data"] * 2},
            {"data": [{"id": "synthetic", "elements": []}]},
            {"data": [{"id": "synthetic", "currency": "GBP", "elements": None}]},
        ]:
            self.assertEqual(checker.tariff_features(body), "unknown")
        body = self.tariff()
        body["data"][0]["elements"][0]["price_components"][0]["type"] = "TIME"
        self.assertEqual(checker.tariff_features(body), "not-observed")

    def test_tariffs_are_opt_in_and_missing_endpoint_is_not_guessed(self):
        opener = Mock()
        result = checker.probe(feed(), {}, opener, tariffs_only=True)
        opener.open.assert_not_called()
        self.assertEqual(result["reason"], "no-published-endpoint")
        opener.open.side_effect = [Response({"data": []}), Response(location())]
        checker.probe(feed(tariffs_url="https://feed.example/tariffs"), {}, opener)
        self.assertEqual(opener.open.call_count, 2)
        self.assertNotIn("tariffs", opener.open.call_args.args[0].full_url)

    def test_two_small_requests_versions_then_one_location(self):
        opener = Mock()
        opener.open.side_effect = [
            Response({"data": [{"version": "2.2.1"}, {"version": "2.1.1"}]}),
            Response(
                location(),
                {"X-Total-Count": "123", "Link": '<private-url>; rel="next"'},
            ),
        ]
        result = checker.probe(feed(), environ={}, opener=opener)
        self.assertEqual(result["outcome"], "open-and-working")
        self.assertEqual(result["versions"], ["2.1.1", "2.2.1"])
        self.assertEqual(result["status"], "observed")
        self.assertEqual(result["tariffs"], "references-only")
        self.assertEqual(result["requests"][1]["total_count"], 123)
        self.assertTrue(result["requests"][1]["link"])
        self.assertNotIn("private-url", str(result))
        calls = opener.open.call_args_list
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0].args[0].full_url, "https://feed.example/versions")
        self.assertEqual(calls[1].args[0].full_url, "https://feed.example/locations?limit=1")
        for call in calls:
            self.assertEqual(call.kwargs, {"timeout": 20})
            self.assertEqual(call.args[0].get_header("User-agent"), checker.USER_AGENT)

    def test_custom_page_size(self):
        opener = Mock()
        opener.open.return_value = Response(location())
        checker.probe(feed(versions_url="", page_size_parameter="per_page"), {}, opener)
        self.assertTrue(opener.open.call_args.args[0].full_url.endswith("?per_page=1"))

    def test_no_invented_endpoints_or_version_detail_calls(self):
        opener = Mock()
        opener.open.return_value = Response(
            {"data": [{"version": "2.2.1", "url": "https://untrusted.example/"}]}
        )
        result = checker.probe(feed(locations_url=""), {}, opener)
        self.assertEqual(opener.open.call_count, 1)
        self.assertNotEqual(result["outcome"], "open-and-working")

    def test_gated_and_rate_limited_responses_stop(self):
        for status, auth, outcome in [
            (401, "token", "needs-key"),
            (401, "basic", "basic-auth"),
            (403, "none", "published-but-failing"),
            (429, "none", "published-but-failing"),
        ]:
            with self.subTest(status=status, auth=auth):
                opener = Mock()
                opener.open.side_effect = HTTPError("url", status, "secret", {}, None)
                result = checker.probe(feed(auth=auth), {}, opener)
                self.assertEqual(opener.open.call_count, 1)
                self.assertEqual(result["outcome"], outcome)
                self.assertNotIn("secret", str(result))

    def test_error_text_and_payloads_never_escape(self):
        for error in [
            URLError("SECRET"),
            TimeoutError("SECRET"),
            ValueError("SECRET"),
            IncompleteRead(b"SECRET"),
        ]:
            opener = Mock()
            opener.open.side_effect = error
            result = checker.probe(feed(versions_url=""), {}, opener)
            self.assertNotIn("SECRET", str(result))
        for body in [
            b"SECRET",
            {"status_code": 2001, "status_message": "SECRET"},
            {"message": "SECRET"},
        ]:
            opener = Mock()
            opener.open.return_value = Response(body)
            result = checker.probe(feed(versions_url=""), {}, opener)
            self.assertNotIn("SECRET", str(result))
            self.assertNotEqual(result["outcome"], "open-and-working")

    def test_no_redirects(self):
        self.assertIsNone(
            checker.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example/")
        )
        opener = Mock()
        opener.open.side_effect = HTTPError(
            "url", 302, "redirect", {"Location": "https://other.example"}, None
        )
        result = checker.probe(feed(versions_url=""), {}, opener)
        self.assertEqual(opener.open.call_count, 1)
        self.assertEqual(result["requests"][0]["http"], 302)

    def test_response_size_bounds_and_content_encoding(self):
        cases = [
            ({"Content-Length": str(checker.MAX_BYTES + 1)}, 0),
            ({"Content-Encoding": "gzip"}, 0),
            ({}, checker.MAX_BYTES),
        ]
        for headers, expected in cases:
            with self.subTest(headers=headers):
                response = Response(b"x" * (checker.MAX_BYTES + 100), headers)
                opener = Mock()
                opener.open.return_value = response
                result = checker.probe(feed(versions_url=""), {}, opener)
                self.assertEqual(response.bytes_read, expected)
                self.assertEqual(result["outcome"], "published-not-sampled")

    def test_empty_unbounded_or_non_locations_are_not_working(self):
        for body in [
            {"data": []},
            {"data": [{"id": "x"}]},
            {"data": location()["data"] * 2},
            {"data": ["bad"]},
        ]:
            opener = Mock()
            opener.open.return_value = Response(body)
            self.assertEqual(
                checker.probe(feed(versions_url=""), {}, opener)["outcome"],
                "published-not-sampled",
            )

    def test_tariff_ids_are_not_prices(self):
        body = location()
        self.assertEqual(checker.sample_features(body)["tariffs"], "references-only")
        body["data"][0]["tariffs"] = [
            {"elements": [{"price_components": [{"type": "ENERGY", "price": 0.5}]}]}
        ]
        self.assertEqual(checker.sample_features(body)["tariffs"], "observed")
        body["data"][0]["tariffs"][0]["elements"][0]["price_components"][0]["type"] = "TIME"
        self.assertEqual(checker.sample_features(body)["tariffs"], "references-only")

    def test_missing_status_is_not_assumed(self):
        body = location()
        body["data"][0]["evses"][0].pop("status")
        self.assertEqual(checker.sample_features(body)["status"], "not-observed")

    def test_malformed_nested_fields_do_not_crash_or_count_as_evidence(self):
        for evse in [
            {"status": [], "connectors": None},
            {"status": {}, "connectors": 1},
        ]:
            body = location()
            body["data"][0]["evses"] = [evse]
            self.assertEqual(checker.sample_features(body)["status"], "not-observed")
            self.assertEqual(checker.sample_features(body)["tariffs"], "not-observed")
        for endpoints in [None, 1, [{"identifier": []}]]:
            opener = Mock()
            opener.open.side_effect = [
                Response({"data": {"endpoints": endpoints}}),
                Response(location()),
            ]
            result = checker.probe(feed(), {}, opener)
            self.assertEqual(result["modules"], [])
            self.assertEqual(len(result["requests"]), 2)

    def test_read_deadline_stops_without_another_read(self):
        response = Response(location())
        opener = Mock()
        opener.open.return_value = response
        with patch.object(checker.time, "monotonic", side_effect=[0, 20]):
            meta, data = checker.request_json("https://feed.example/", {}, opener)
        self.assertEqual(meta["result"], "timeout")
        self.assertEqual(response.bytes_read, 0)
        self.assertIsNone(data)

    def test_env_credentials_only_and_no_secret_in_results(self):
        for auth, header, scheme, secret in [
            ("basic", "Authorization", "Basic", "user:pass"),
            ("token", "Authorization", "Token", "synthetic-secret"),
            ("emailed-key", "ec-subscription-key", "", "synthetic-key"),
            ("emailed-key", "x-api-key", "", "synthetic-fastned-key"),
            ("token", "authorization", "Bearer", "synthetic-bearer"),
        ]:
            with self.subTest(auth=auth):
                f = feed(
                    versions_url="",
                    auth=auth,
                    credential_env="OCPI_FEED_SAMPLE_TOKEN",
                    auth_header=header,
                    auth_scheme=scheme,
                )
                opener = Mock()
                opener.open.return_value = Response(location())
                result = checker.probe(f, {f["credential_env"]: secret}, opener)
                self.assertNotIn(secret, str(result))
                value = opener.open.call_args.args[0].get_header(header.capitalize())
                expected = (
                    "Basic " + base64.b64encode(secret.encode()).decode()
                    if auth == "basic"
                    else ((scheme + " ") if scheme else "") + secret
                )
                self.assertEqual(value, expected)
                self.assertNotEqual(result["outcome"], "open-and-working")
        self.assertNotIn(
            "Authorization",
            checker.headers_for(
                feed(auth="token", credential_env="EXPECTED"), {"UNRELATED": "secret"}
            ),
        )

    def test_invalid_credentials_urls_and_skip_do_not_request(self):
        cases = [
            feed(locations_url="http://feed.example/locations"),
            feed(locations_url="https://u:p@feed.example/locations"),
            feed(locations_url="https://feed.example/locations?token=x"),
            feed(probe_skip="bulk-only"),
            feed(
                auth="token",
                credential_env="KEY",
                auth_header="Authorization",
                auth_scheme="Token",
            ),
        ]
        for f in cases:
            opener = Mock()
            checker.probe(f, {"KEY": "bad\ncredential"}, opener)
            opener.open.assert_not_called()

    def test_cli_does_not_print_remote_metadata(self):
        f = feed()
        result = checker.probe(feed(versions_url="", locations_url=""), {})
        output = io.StringIO()
        with (
            patch.object(checker.tomllib, "loads", return_value={"feed": [f]}),
            patch.object(checker, "probe", return_value=result),
            redirect_stdout(output),
        ):
            checker.main([])
        self.assertIn("not-published", output.getvalue())


class RegisterTests(unittest.TestCase):
    def setUp(self):
        self.feeds = tomllib.loads(checker.REGISTER.read_text())["feed"]

    def test_schema_and_safe_public_register(self):
        required = {
            "id",
            "name",
            "website",
            "open_data_page",
            "base_url",
            "format",
            "ocpi_version",
            "modules",
            "has_status",
            "has_tariffs",
            "auth",
            "credential_env",
            "terms",
            "rate_limit",
            "sites_approx",
            "checked_on",
            "check_result",
            "notes",
            "sources",
        }
        self.assertEqual(len(self.feeds), len({f["id"] for f in self.feeds}))
        for f in self.feeds:
            with self.subTest(id=f["id"]):
                self.assertTrue(required <= f.keys())
                self.assertIn(f["check_result"], checker.OUTCOMES)
                self.assertIn(f["auth"], {"none", "token", "basic", "emailed-key", "unknown"})
                if f["credential_env"]:
                    self.assertRegex(f["credential_env"], r"^OCPI_FEED_[A-Z0-9_]+_(TOKEN|BASIC)$")
                for key in ["base_url", "versions_url", "locations_url", "tariffs_url"]:
                    if f.get(key):
                        self.assertTrue(checker.safe_url(f[key]), key)
                self.assertTrue(f["sources"])
                self.assertIsInstance(f["sites_approx"], int)

    def test_eco_movement_register_sends_documented_token_header(self):
        feeds = [f for f in self.feeds if "open-chargepoints.com" in f["base_url"]]
        self.assertGreaterEqual(len(feeds), 7)
        for f in feeds:
            with self.subTest(id=f["id"]):
                opener = Mock()
                opener.open.return_value = Response(location())
                checker.probe(f, {f["credential_env"]: "synthetic-token"}, opener)
                self.assertEqual(
                    opener.open.call_args.args[0].get_header("Authorization"),
                    "Token synthetic-token",
                )

    def test_documentation_matches_all_register_columns_in_order(self):
        root = Path(__file__).resolve().parents[3]
        doc = (root / "docs/ev-charging-open-data-feeds.md").read_text()
        stored = doc.split("<!-- register:start -->\n", 1)[1].split("\n<!-- register:end -->", 1)[0]
        self.assertEqual(stored, checker.markdown_table(self.feeds))

    def test_all_requested_anchor_names_have_rows_or_aliases(self):
        text = json.dumps(self.feeds).lower()
        for name in [
            "tesla",
            "bp pulse",
            "shell recharge",
            "ubitricity",
            "pod point",
            "instavolt",
            "gridserve",
            "ionity",
            "osprey",
            "mfg",
            "fastned",
            "be.ev",
            "believ",
            "char.gy",
            "connected kerb",
            "smart charge",
            "geniepoint",
            "mer",
            "allego",
            "source",
            "chargeplace scotland",
            "liberty charge",
            "raw",
            "zest",
            "swarco",
            "evyve",
            "blink",
            "trojan",
            "joju",
            "equans",
            "plug-n-go",
            "esb",
            "eb charging",
            "electric highway",
        ]:
            self.assertIn(name, text)


if __name__ == "__main__":
    unittest.main()
