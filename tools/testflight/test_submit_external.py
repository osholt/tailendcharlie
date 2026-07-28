import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("submit_external.py")
SPEC = importlib.util.spec_from_file_location("submit_external", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
SUBMIT_EXTERNAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUBMIT_EXTERNAL)


class FakeClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def request(self, method, path, **kwargs):
        self.requests.append((method, path, kwargs))
        return self.responses.pop(0)


class SubmitExternalTests(unittest.TestCase):
    def test_existing_group_and_approved_submission_are_idempotent(self):
        client = FakeClient(
            [
                {"data": [{"id": "group-1"}]},
                {
                    "data": [
                        {
                            "attributes": {
                                "betaReviewState": "APPROVED",
                            }
                        }
                    ]
                },
            ]
        )

        added = SUBMIT_EXTERNAL.ensure_group_access(
            client,
            build_id="build-1",
            group={"id": "group-1"},
            dry_run=False,
        )
        state, submitted = SUBMIT_EXTERNAL.submit_for_review(
            client,
            build_id="build-1",
            dry_run=False,
        )

        self.assertFalse(added)
        self.assertEqual(state, "APPROVED")
        self.assertFalse(submitted)
        self.assertEqual([request[0] for request in client.requests], ["GET", "GET"])

    def test_new_build_is_assigned_and_submitted(self):
        client = FakeClient(
            [
                {"data": []},
                {},
                {"data": []},
                {
                    "data": {
                        "attributes": {
                            "betaReviewState": "WAITING_FOR_REVIEW",
                        }
                    }
                },
            ]
        )

        added = SUBMIT_EXTERNAL.ensure_group_access(
            client,
            build_id="build-1",
            group={"id": "group-1"},
            dry_run=False,
        )
        state, submitted = SUBMIT_EXTERNAL.submit_for_review(
            client,
            build_id="build-1",
            dry_run=False,
        )

        self.assertTrue(added)
        self.assertEqual(state, "WAITING_FOR_REVIEW")
        self.assertTrue(submitted)
        self.assertEqual(
            [request[0] for request in client.requests],
            ["GET", "POST", "GET", "POST"],
        )

    def test_rejected_submission_fails(self):
        client = FakeClient(
            [
                {
                    "data": [
                        {
                            "attributes": {
                                "betaReviewState": "REJECTED",
                            }
                        }
                    ]
                }
            ]
        )

        with self.assertRaises(SUBMIT_EXTERNAL.AppStoreConnectError):
            SUBMIT_EXTERNAL.submit_for_review(
                client,
                build_id="build-1",
                dry_run=False,
            )


if __name__ == "__main__":
    unittest.main()
