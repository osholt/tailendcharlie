from __future__ import annotations

import io
import sys
import tempfile
import unittest
from email.utils import getaddresses
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.tester_notify.notify_testers import (  # noqa: E402
    ALLOWED_LINK_HOSTS,
    TRACK_LABELS,
    ReleaseContext,
    UnsafeContentError,
    assert_safe,
    build_message,
    decide,
    is_single_address,
    main,
    mask_recipient,
    read_changes,
    render_email,
    smtp_settings,
    summary_markdown,
)

# Not a credential: no SMTP server accepts it and nothing in this repository
# stores one. Named so no scanner mistakes it for real material.
FAKE_LOGIN_VALUE = "placeholder-value-never-a-credential"
LOGIN_ENV = "TESTER_NOTIFY_SMTP_PASSWORD"
RECIPIENT = "tailendcharlie-testers@example.invalid"


def smtp_env(**overrides: str) -> dict:
    env = {
        "TESTER_NOTIFY_FROM": "releases@example.invalid",
        "TESTER_NOTIFY_SMTP_HOST": "smtp.example.invalid",
        "TESTER_NOTIFY_SMTP_PORT": "587",
        "TESTER_NOTIFY_SMTP_USERNAME": "releases@example.invalid",
        LOGIN_ENV: FAKE_LOGIN_VALUE,
    }
    env.update(overrides)
    return {name: value for name, value in env.items() if value is not None}


def context(**overrides) -> ReleaseContext:
    values = {
        "track": "alpha",
        "app_version": "1.0.1",
        "build_number": "31",
        "commit": "ce39e51ab0d4f6e8c1b2a3d4e5f60718293a4b5c",
        "repository": "osholt/tailendcharlie",
        "run_url": "https://github.com/osholt/tailendcharlie/actions/runs/12345",
        "changes": (
            "- reroute off-course riders back to the route (ce39e51)",
            "- correct roundabout and lane guidance (6b56c7b)",
        ),
        "changes_baseline": "build 28 (commit 67853ec)",
    }
    values.update(overrides)
    return ReleaseContext(**values)


def cli_args(**overrides) -> list:
    values = {
        "--track": "alpha",
        "--app-version": "1.0.1",
        "--build-number": "31",
        "--commit": "ce39e51ab0d4f6e8c1b2a3d4e5f60718293a4b5c",
        "--repository": "osholt/tailendcharlie",
        "--run-url": "https://github.com/osholt/tailendcharlie/actions/runs/1",
        "--recipient": RECIPIENT,
        "--mode": "auto",
    }
    values.update(overrides)
    argv = []
    for flag, value in values.items():
        argv.extend([flag, value])
    return argv


class RenderingTest(unittest.TestCase):
    def test_states_everything_a_tester_needs_to_act(self) -> None:
        email = render_email(context())

        self.assertEqual(
            email.subject,
            "Tail End Charlie 1.0.1 (31) is on Play closed testing (alpha)",
        )
        for required in [
            "1.0.1",
            "build 31",
            "Google Play version code",
            "Android",
            "Play closed testing (alpha)",
            "ce39e51",
            "https://github.com/osholt/tailendcharlie/commit/ce39e51",
            "https://play.google.com/apps/testing/app.tailendcharlie",
            "About & build",
            "Distribution track  Play closed testing (alpha)",
            "WHAT CHANGED since build 28 (commit 67853ec)",
            "- reroute off-course riders back to the route (ce39e51)",
            "docs/tester-update-guide.md",
            "docs/tester-release-notes.md",
        ]:
            self.assertIn(required, email.body, required)

    def test_beta_track_renders_its_own_label(self) -> None:
        email = render_email(context(track="beta"))

        self.assertIn("Play closed testing (beta)", email.subject)
        self.assertIn("Play closed testing (beta)", email.body)

    def test_says_so_when_no_change_list_was_produced(self) -> None:
        email = render_email(context(changes=(), changes_baseline=""))

        self.assertIn("no commit list available", email.body)
        self.assertIn("the previous notified build", email.body)

    def test_track_labels_match_the_app(self) -> None:
        # A tester compares this mail against Settings -> About & build, so the
        # two strings must be the same string.
        dart = (ROOT / "apps/mobile/lib/services/build_identity.dart").read_text("utf-8")
        for label in TRACK_LABELS.values():
            self.assertIn(f"'{label}'", dart)
        self.assertIn(
            f"'{context().opt_in_url}'",
            dart,
            "the mail and the in-app update button must use one opt-in URL",
        )


class SafetyTest(unittest.TestCase):
    def test_allows_only_store_and_repository_links(self) -> None:
        self.assertEqual(ALLOWED_LINK_HOSTS, {"play.google.com", "github.com"})
        assert_safe(render_email(context()).body)

    def test_refuses_a_relay_url(self) -> None:
        with self.assertRaises(UnsafeContentError):
            assert_safe("update at https://relay.tailendcharlie.app/api/v1/x")

    def test_refuses_plaintext_and_credential_bearing_links(self) -> None:
        with self.assertRaises(UnsafeContentError):
            assert_safe("http://play.google.com/apps/testing/app.tailendcharlie")
        with self.assertRaises(UnsafeContentError):
            assert_safe("https://user:pass@github.com/osholt/tailendcharlie")

    def test_a_relay_url_smuggled_through_the_changelog_is_caught(self) -> None:
        with self.assertRaises(UnsafeContentError):
            render_email(context(changes=("- see https://relay.tailendcharlie.app/api",)))

    def test_masks_the_group_address(self) -> None:
        self.assertEqual(
            mask_recipient("testers@googlegroups.com"),
            "t***@googlegroups.com",
        )
        self.assertEqual(mask_recipient("nonsense"), "***")


class ConfigurationTest(unittest.TestCase):
    def test_unset_recipient_is_a_dry_run_not_a_guess(self) -> None:
        decision = decide("auto", "", ())

        self.assertEqual(decision.action, "dry-run")
        self.assertIn("RIDE_RELAY_ANDROID_TESTER_GROUP", decision.reason)

    def test_dry_run_mode_wins_over_full_configuration(self) -> None:
        self.assertEqual(decide("dry-run", RECIPIENT, ()).action, "dry-run")

    def test_refuses_a_recipient_that_is_not_one_plain_address(self) -> None:
        for value in (
            "one@example.invalid, two@example.invalid",
            "one@example.invalid\nBcc: three@example.invalid",
            "not-an-address",
        ):
            self.assertFalse(is_single_address(value), value)
            self.assertEqual(decide("auto", value, ()).action, "skip")
        self.assertTrue(is_single_address(" testers@example.invalid "))

    def test_names_the_missing_settings_rather_than_failing(self) -> None:
        settings, missing = smtp_settings({"TESTER_NOTIFY_FROM": "a@b.invalid"})

        self.assertIsNone(settings)
        self.assertIn("TESTER_NOTIFY_SMTP_HOST", missing)
        decision = decide("auto", RECIPIENT, missing)
        self.assertEqual(decision.action, "skip")
        self.assertIn("TESTER_NOTIFY_SMTP_HOST", decision.reason)

    def test_complete_configuration_sends(self) -> None:
        settings, missing = smtp_settings(smtp_env())

        self.assertEqual(missing, ())
        self.assertIsNotNone(settings)
        self.assertEqual(settings.port, 587)
        self.assertEqual(decide("auto", RECIPIENT, missing).action, "send")

    def test_reads_changes_from_a_file_and_tolerates_its_absence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "changes.md"
            path.write_text("- one (abc1234)\n\n- two (def5678)\n", "utf-8")

            self.assertEqual(
                read_changes(str(path)),
                ("- one (abc1234)", "- two (def5678)"),
            )
        self.assertEqual(read_changes(str(path)), ())
        self.assertEqual(read_changes(""), ())


class MainTest(unittest.TestCase):
    def setUp(self) -> None:
        self.sent = []
        self.out = io.StringIO()

    def transport(self, message, settings) -> None:
        self.sent.append((message, settings))

    def test_no_recipient_renders_into_the_summary_and_sends_nothing(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            env = smtp_env()
            env["GITHUB_STEP_SUMMARY"] = str(summary)

            code = main(
                cli_args(**{"--recipient": ""}),
                env=env,
                transport=self.transport,
                out=self.out,
            )

            rendered = summary.read_text("utf-8")
        self.assertEqual(code, 0)
        self.assertEqual(self.sent, [])
        self.assertIn("Rendered only, not sent", rendered)
        self.assertIn("Play closed testing (alpha)", rendered)
        self.assertIn("RIDE_RELAY_ANDROID_TESTER_GROUP", rendered)
        self.assertIn("::notice::", self.out.getvalue())

    def test_missing_credentials_skip_visibly_and_keep_the_release_green(
        self,
    ) -> None:
        code = main(cli_args(), env={}, transport=self.transport, out=self.out)

        self.assertEqual(code, 0)
        self.assertEqual(self.sent, [])
        output = self.out.getvalue()
        self.assertIn("Not sent", output)
        self.assertIn("TESTER_NOTIFY_SMTP_HOST", output)

    def test_dry_run_mode_never_sends_even_when_fully_configured(self) -> None:
        code = main(
            cli_args(**{"--mode": "dry-run"}),
            env=smtp_env(),
            transport=self.transport,
            out=self.out,
        )

        self.assertEqual(code, 0)
        self.assertEqual(self.sent, [])
        self.assertIn("Rendered only, not sent", self.out.getvalue())

    def test_configured_send_addresses_the_group_and_hides_the_credential(
        self,
    ) -> None:
        code = main(
            cli_args(),
            env=smtp_env(),
            transport=self.transport,
            out=self.out,
        )

        self.assertEqual(code, 0)
        self.assertEqual(len(self.sent), 1)
        message, settings = self.sent[0]
        self.assertEqual(message["To"], RECIPIENT)
        self.assertEqual(message["From"], "releases@example.invalid")
        self.assertEqual(message["Auto-Submitted"], "auto-generated")
        self.assertIn("Play closed testing (alpha)", message.get_content())
        self.assertEqual(settings.password, FAKE_LOGIN_VALUE)
        output = self.out.getvalue()
        self.assertNotIn(FAKE_LOGIN_VALUE, output)
        self.assertNotIn(RECIPIENT, output)
        self.assertIn("t***@example.invalid", output)

    def test_refuses_to_mail_an_unidentified_build(self) -> None:
        code = main(
            cli_args(**{"--build-number": "  "}),
            env=smtp_env(),
            transport=self.transport,
            out=self.out,
        )

        self.assertEqual(code, 0)
        self.assertEqual(self.sent, [])
        self.assertIn("::error::", self.out.getvalue())
        self.assertIn("--build-number", self.out.getvalue())

    def test_a_delivery_failure_is_loud_but_never_fatal(self) -> None:
        def failing(message, settings):
            raise OSError("connection refused")

        code = main(cli_args(), env=smtp_env(), transport=failing, out=self.out)

        self.assertEqual(code, 0)
        output = self.out.getvalue()
        self.assertIn("::error::", output)
        self.assertIn("connection refused", output)
        self.assertIn("Rendered only, not sent", output)

    def test_summary_never_carries_the_full_recipient(self) -> None:
        markdown = summary_markdown(
            render_email(context()),
            decide("auto", RECIPIENT, ()),
            RECIPIENT,
            delivered=True,
        )

        self.assertNotIn(RECIPIENT, markdown)
        self.assertIn("t***@example.invalid", markdown)
        self.assertIn("Sent to", markdown)

    def test_a_display_name_reaches_the_header_but_not_the_envelope(self) -> None:
        """The From may carry a friendly name; the envelope may not.

        Testers see "Tail End Charlie" rather than a bare address, which is what
        `RIDE_RELAY_TESTER_NOTIFY_FROM` is set to in this repository.

        The envelope sender has to stay the bare address, because the sending box
        enforces Postfix's `reject_authenticated_sender_login_mismatch`: an
        envelope of `Tail End Charlie <testing@...>` would not match the SASL
        login and every release mail would be rejected. `send_message` derives
        the envelope from this header, so the two are one string in the code and
        two different strings on the wire — exactly the kind of thing a later
        refactor breaks silently.
        """
        message = build_message(
            render_email(context()),
            "Tail End Charlie <releases@example.invalid>",
            RECIPIENT,
        )

        self.assertEqual(message["From"], "Tail End Charlie <releases@example.invalid>")
        # Precisely what smtplib.send_message does to pick MAIL FROM.
        envelope = getaddresses([message["From"]])[0][1]
        self.assertEqual(envelope, "releases@example.invalid")

    def test_builds_a_plain_text_message(self) -> None:
        message = build_message(render_email(context()), "releases@example.invalid", RECIPIENT)

        self.assertEqual(message.get_content_type(), "text/plain")
        self.assertIn("HOW TO GET IT", message.get_content())


if __name__ == "__main__":
    unittest.main()
