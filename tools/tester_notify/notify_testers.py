#!/usr/bin/env python3
"""Render - and only then, if configured, send - the Android closed-track
tester notification.

Called by `.github/workflows/android-internal.yml` after a build has been
promoted to the closed track testers actually install from. It is deliberately
Android-only: TestFlight already emails iOS testers when a build arrives, and a
second mail would be duplicate noise.

Safety, in order of importance:

* It never guesses a recipient. With `RIDE_RELAY_ANDROID_TESTER_GROUP` unset the
  run renders the mail into the job summary and sends nothing.
* It never fails a release. Every configuration and delivery outcome exits 0
  with a visible annotation; the caller also runs it `continue-on-error`.
* It never carries relay URLs, ride codes or tester data. Every link in the
  rendered mail is checked against `ALLOWED_LINK_HOSTS` before it can be sent.
* Credentials come from the environment (repository secrets), never arguments,
  and are never written to the summary or the log.

Usage:

    python3 tools/tester_notify/notify_testers.py \\
      --track alpha --app-version 1.0.1 --build-number 31 \\
      --commit "$GITHUB_SHA" --repository osholt/tailendcharlie \\
      --run-url https://github.com/osholt/tailendcharlie/actions/runs/1 \\
      --changes-file changes.md --changes-baseline 'build 30' \\
      --recipient "$TESTER_GROUP" --mode auto
"""

from __future__ import annotations

import argparse
import html as html_module
import os
import re
import smtplib
import ssl
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from email.message import EmailMessage
from pathlib import Path

PACKAGE_NAME = "app.tailendcharlie"

#: Pre-sized, corner-rounded app icon embedded into the HTML mail by CID.
#: Committed next to this tool rather than resized at send time so the mail
#: needs no imaging library on the runner. Its absence is never an error -
#: the mail degrades to text-only branding (#631).
MAIL_ICON_PATH = Path(__file__).with_name("mail-icon.png")
MAIL_ICON_CID = "app-icon"


def load_mail_icon() -> bytes | None:
    try:
        return MAIL_ICON_PATH.read_bytes()
    except OSError:
        return None


# Must stay identical to DistributionTrack's labels in
# apps/mobile/lib/services/build_identity.dart: the mail tells a tester what
# "About & build" will show them, so a mismatch is a support conversation.
TRACK_LABELS = {
    "alpha": "Play closed testing (alpha)",
    "beta": "Play closed testing (beta)",
}

# Every link the mail may contain. The relay's base URL can carry a path and, if
# misconfigured, a token; nothing about the relay belongs in a tester mail.
ALLOWED_LINK_HOSTS = frozenset({"play.google.com", "github.com"})

_URL = re.compile(r"https?://[^\s<>)\]\"']+")

SMTP_ENV_VARS = (
    "TESTER_NOTIFY_FROM",
    "TESTER_NOTIFY_SMTP_HOST",
    "TESTER_NOTIFY_SMTP_USERNAME",
    "TESTER_NOTIFY_SMTP_PASSWORD",
)


class UnsafeContentError(ValueError):
    """Raised when rendered content carries a link that must never be mailed."""


@dataclass(frozen=True)
class ReleaseContext:
    """Everything the mail is allowed to know about a release."""

    track: str
    app_version: str
    build_number: str
    commit: str
    repository: str
    run_url: str
    changes: tuple[str, ...] = ()
    changes_baseline: str = ""

    @property
    def track_label(self) -> str:
        return TRACK_LABELS.get(self.track, "Play closed testing")

    @property
    def short_commit(self) -> str:
        return self.commit[:7]

    @property
    def opt_in_url(self) -> str:
        return "https://play.google.com/apps/testing/" + PACKAGE_NAME

    @property
    def commit_url(self) -> str:
        return f"https://github.com/{self.repository}/commit/{self.commit}"

    def doc_url(self, name: str) -> str:
        return f"https://github.com/{self.repository}/blob/{self.commit}/docs/{name}"


@dataclass(frozen=True)
class RenderedEmail:
    subject: str
    body: str
    #: The TestFlight-shaped HTML alternative (#631). The plain body above
    #: remains the first part of the multipart/alternative and what the run
    #: summary renders, so a client that strips HTML loses nothing.
    html: str


@dataclass(frozen=True)
class SmtpSettings:
    sender: str
    host: str
    port: int
    username: str
    password: str


@dataclass(frozen=True)
class Decision:
    """What the step is going to do, and the sentence explaining it."""

    action: str  # "send" | "dry-run" | "skip"
    reason: str


def render_subject(context: ReleaseContext) -> str:
    build = f"{context.app_version} ({context.build_number})"
    return f"Tail End Charlie {build} is on {context.track_label}"


def render_body(context: ReleaseContext) -> str:
    baseline = context.changes_baseline or "the previous notified build"
    changes = list(context.changes) or [
        "- (no commit list available for this release - see the tester notes)"
    ]
    build = f"{context.app_version} (build {context.build_number})"
    lines = [
        f"Tail End Charlie {build} is now on {context.track_label}.",
        "",
        f"  App version    {context.app_version}",
        f"  Build number   {context.build_number}  (the Google Play version code)",
        "  Platform       Android",
        f"  Track          {context.track_label}",
        f"  Built from     {context.short_commit}",
        f"                 {context.commit_url}",
        "",
        "HOW TO GET IT",
        "  1. On the phone you ride with, signed in with the Google account you",
        "     test on, open the closed-testing opt-in page:",
        f"     {context.opt_in_url}",
        "  2. If it says you are not a tester yet, accept the invitation there.",
        '     Then follow "Download it on Google Play".',
        "  3. Choose Update in Google Play. A new closed-testing build can take",
        "     a few minutes to be offered; if it is not there yet, wait, then",
        "     pull to refresh under Manage apps & device > Updates available.",
        "",
        "CONFIRM YOU ARE ON THIS BUILD",
        '  Open Tail End Charlie, tap the gear icon, then "About & build".',
        "  It must show:",
        f"     App version         {context.app_version}",
        f"     Build number        {context.build_number}",
        f"     Distribution track  {context.track_label}",
        '  "Copy build details for a bug report" copies exactly that. Paste it',
        "  into every report - a report without it cannot be matched to code.",
        "",
        f"WHAT CHANGED since {baseline}",
    ]
    lines.extend(changes)
    lines.extend(
        [
            "",
            "Tester notes for every build: " + context.doc_url("tester-release-notes.md"),
            "Full tester guide: " + context.doc_url("tester-update-guide.md"),
            f"Build produced by: {context.run_url}",
            "",
            "You are receiving this because you are on the Tail End Charlie",
            "closed tester list. Tell the maintainer if you want to leave it.",
        ]
    )
    return "\n".join(lines) + "\n"


def assert_safe(text: str) -> None:
    """Refuse content carrying a link that is not a store or repository link."""
    for match in _URL.finditer(text):
        url = match.group(0)
        if not url.startswith("https://"):
            raise UnsafeContentError("refusing to send a non-HTTPS link: " + url)
        remainder = url[len("https://") :]
        host = remainder.split("/", 1)[0]
        if "@" in host:
            raise UnsafeContentError("refusing to send a link with credentials")
        if host.split(":", 1)[0] not in ALLOWED_LINK_HOSTS:
            raise UnsafeContentError("refusing to send a link to " + host)


def render_html(context: ReleaseContext, *, with_icon: bool) -> str:
    """The TestFlight-shaped alternative: icon, headline, paragraphs, footer.

    Every interpolated value passes through `html_module.escape` - the change
    list is commit subjects, which are arbitrary text - and the finished
    document goes through `assert_safe` like the plain body, so the HTML can
    carry exactly the links the text can and no others. Styling is inline and
    table-based because mail clients ignore stylesheets.
    """
    esc = html_module.escape
    build = esc(f"{context.app_version} ({context.build_number})")
    baseline = esc(context.changes_baseline or "the previous notified build")
    changes = [
        line[2:] if line.startswith("- ") else line
        for line in (context.changes or ("(no commit list available for this release)",))
    ]
    change_items = "\n".join(f'<li style="margin:0 0 6px 0;">{esc(line)}</li>' for line in changes)
    link = '<a href="{url}" style="color:#0066cc;text-decoration:none;">{label}</a>'
    font = "-apple-system,'SF Pro Text','Helvetica Neue',Helvetica,Arial,sans-serif"
    column_style = f"max-width:600px;width:100%;font-family:{font};"
    h1_style = "font-size:28px;line-height:34px;font-weight:600;color:#1d1d1f;padding-bottom:28px;"
    para_style = "font-size:17px;line-height:25px;color:#1d1d1f;"
    h2_style = "font-size:17px;line-height:25px;font-weight:600;color:#1d1d1f;padding-bottom:8px;"
    list_cell_style = "font-size:15px;line-height:22px;color:#1d1d1f;padding-bottom:22px;"
    footer_style = (
        "border-top:1px solid #d2d2d7;padding-top:18px;font-size:12px;"
        "line-height:18px;color:#6e6e73;"
    )
    notes_link = link.format(
        url=esc(context.doc_url("tester-release-notes.md")),
        label="Tester notes for every build",
    )
    guide_link = link.format(
        url=esc(context.doc_url("tester-update-guide.md")),
        label="Full tester guide",
    )
    run_link = link.format(url=esc(context.run_url), label="Build run")
    icon_block = (
        (
            '<img src="cid:' + MAIL_ICON_CID + '" width="120" height="120" '
            'alt="Tail End Charlie" '
            'style="display:block;margin:0 auto 28px auto;border:0;" />'
        )
        if with_icon
        else ""
    )
    about_row = (
        '<tr><td style="padding:2px 14px 2px 0;color:#6e6e73;">{name}</td>'
        '<td style="padding:2px 0;color:#1d1d1f;">{value}</td></tr>'
    )
    return f"""<!DOCTYPE html>
<html>
<body style="margin:0;padding:0;background-color:#ffffff;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
         style="background-color:#ffffff;">
    <tr><td align="center" style="padding:40px 16px;">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0"
             style="{column_style}">
        <tr><td style="padding-bottom:4px;">{icon_block}</td></tr>
        <tr><td align="center" style="{h1_style}">
          Tail End Charlie {build} is ready to test on Android.
        </td></tr>
        <tr><td style="{para_style}padding-bottom:18px;">
          To test this build, open the
          {link.format(url=esc(context.opt_in_url), label="closed-testing opt-in page")}
          on the phone you ride with, signed in with the Google account you test
          on, then install the update from Google Play. A new build can take a
          few minutes to be offered.
        </td></tr>
        <tr><td style="{para_style}padding-bottom:8px;">
          Confirm you are on this build under
          <strong>Settings &#8594; About &amp; build</strong>:
        </td></tr>
        <tr><td style="padding:0 0 22px 0;">
          <table role="presentation" cellpadding="0" cellspacing="0"
                 style="font-size:15px;line-height:22px;">
            {about_row.format(name="App version", value=esc(context.app_version))}
            {about_row.format(name="Build number", value=esc(context.build_number))}
            {about_row.format(name="Distribution track", value=esc(context.track_label))}
          </table>
        </td></tr>
        <tr><td style="{h2_style}">
          What changed since {baseline}
        </td></tr>
        <tr><td style="{list_cell_style}">
          <ul style="margin:0;padding-left:20px;">
{change_items}
          </ul>
        </td></tr>
        <tr><td style="font-size:15px;line-height:22px;padding-bottom:28px;">
          {notes_link}
          &nbsp;&#183;&nbsp;
          {guide_link}
          &nbsp;&#183;&nbsp;
          {run_link}
        </td></tr>
        <tr><td style="{footer_style}">
          Built from commit
          {link.format(url=esc(context.commit_url), label=esc(context.short_commit))}.
          You are receiving this because you are on the Tail End Charlie closed
          tester list. Tell the maintainer if you want to leave it. Paste the
          About &amp; build details into every bug report - a report without
          them cannot be matched to code.
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
"""


def render_email(context: ReleaseContext, *, with_icon: bool = True) -> RenderedEmail:
    email = RenderedEmail(
        render_subject(context),
        render_body(context),
        render_html(context, with_icon=with_icon),
    )
    assert_safe(email.subject)
    assert_safe(email.body)
    assert_safe(email.html)
    return email


def build_message(
    email: RenderedEmail,
    sender: str,
    recipient: str,
    icon: bytes | None = None,
) -> EmailMessage:
    message = EmailMessage()
    message["Subject"] = email.subject
    message["From"] = sender
    message["To"] = recipient
    message["Auto-Submitted"] = "auto-generated"
    message.set_content(email.body)
    # The HTML alternative last, so clients that honour order prefer it. With
    # an icon the alternative becomes multipart/related carrying the image by
    # CID - embedded, not hotlinked, because the mail must not depend on any
    # host being up (#631).
    message.add_alternative(email.html, subtype="html")
    if icon is not None:
        message.get_payload()[-1].add_related(
            icon,
            maintype="image",
            subtype="png",
            cid=f"<{MAIL_ICON_CID}>",
        )
    return message


def mask_recipient(recipient: str) -> str:
    """Keep a private list address out of a public run summary."""
    if "@" not in recipient:
        return "***"
    local, _, domain = recipient.partition("@")
    return f"{local[:1]}***@{domain}"


def read_changes(path: str | None) -> tuple[str, ...]:
    if not path:
        return ()
    source = Path(path)
    if not source.is_file():
        return ()
    lines = [line.rstrip() for line in source.read_text("utf-8").splitlines()]
    return tuple(line for line in lines if line.strip())


def smtp_settings(env: dict[str, str]) -> tuple[SmtpSettings | None, tuple[str, ...]]:
    """Resolve SMTP settings, or report exactly which ones are missing."""
    missing = tuple(name for name in SMTP_ENV_VARS if not env.get(name, "").strip())
    if missing:
        return None, missing
    raw_port = env.get("TESTER_NOTIFY_SMTP_PORT", "").strip() or "587"
    try:
        port = int(raw_port)
    except ValueError:
        return None, ("TESTER_NOTIFY_SMTP_PORT (not a number)",)
    return (
        SmtpSettings(
            sender=env["TESTER_NOTIFY_FROM"].strip(),
            host=env["TESTER_NOTIFY_SMTP_HOST"].strip(),
            port=port,
            username=env["TESTER_NOTIFY_SMTP_USERNAME"].strip(),
            password=env["TESTER_NOTIFY_SMTP_PASSWORD"],
        ),
        (),
    )


def is_single_address(value: str) -> bool:
    """One plain address, so a stray newline cannot become a header."""
    candidate = value.strip()
    if any(character in candidate for character in "\r\n,; "):
        return False
    return candidate.count("@") == 1


def decide(mode: str, recipient: str, missing_settings: Sequence[str]) -> Decision:
    if mode == "dry-run":
        return Decision("dry-run", "dry-run mode was requested, so nothing was sent.")
    if not recipient.strip():
        return Decision(
            "dry-run",
            "no tester group is configured. Set the "
            "RIDE_RELAY_ANDROID_TESTER_GROUP repository variable to send this "
            "mail; until then every run renders it here and sends nothing.",
        )
    if not is_single_address(recipient):
        return Decision(
            "skip",
            "RIDE_RELAY_ANDROID_TESTER_GROUP is not a single plain address. "
            "Set it to one group address; this tool will not split a list or "
            "risk a header it did not build. Nothing was sent.",
        )
    if missing_settings:
        return Decision(
            "skip",
            "a recipient is configured but the sending identity is not. Unset: "
            + ", ".join(missing_settings)
            + ". Nothing was sent.",
        )
    return Decision("send", "sending to the configured tester group.")


def send_via_smtp(message: EmailMessage, settings: SmtpSettings) -> None:
    """Deliver over an encrypted connection, or not at all."""
    context = ssl.create_default_context()
    if settings.port == 465:
        with smtplib.SMTP_SSL(settings.host, settings.port, context=context, timeout=30) as smtp:
            smtp.login(settings.username, settings.password)
            smtp.send_message(message)
        return
    with smtplib.SMTP(settings.host, settings.port, timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls(context=context)
        smtp.ehlo()
        smtp.login(settings.username, settings.password)
        smtp.send_message(message)


def summary_markdown(
    email: RenderedEmail, decision: Decision, recipient: str, delivered: bool
) -> str:
    if delivered:
        status = f"Sent to {mask_recipient(recipient)}"
    elif decision.action == "skip":
        status = "Not sent"
    else:
        status = "Rendered only, not sent"
    destination = mask_recipient(recipient) if recipient.strip() else "(unset)"
    return "\n".join(
        [
            "## Closed-track tester notification",
            "",
            f"- Status: **{status}**",
            f"- Why: {decision.reason}",
            f"- Recipient variable: `RIDE_RELAY_ANDROID_TESTER_GROUP` = {destination} (masked)",
            "",
            "### Subject",
            "",
            "```",
            email.subject,
            "```",
            "",
            "### Body",
            "",
            "```",
            email.body.rstrip("\n"),
            "```",
            "",
        ]
    )


def _write_summary(env: dict[str, str], markdown: str, out) -> None:
    path = env.get("GITHUB_STEP_SUMMARY", "").strip()
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(markdown)
        return
    out.write(markdown)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--track", required=True, choices=sorted(TRACK_LABELS))
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--changes-file", default="")
    parser.add_argument("--changes-baseline", default="")
    parser.add_argument(
        "--recipient",
        default="",
        help="Tester group address from a repository variable. Empty means "
        "dry run: this tool never guesses a recipient.",
    )
    parser.add_argument("--mode", default="auto", choices=("auto", "dry-run"))
    return parser.parse_args(list(argv))


def main(
    argv: Sequence[str],
    env: dict[str, str] | None = None,
    transport: Callable[[EmailMessage, SmtpSettings], None] | None = None,
    out=None,
) -> int:
    """Always returns 0: a tester mail must never fail a release."""
    environment = dict(os.environ if env is None else env)
    stream = out or sys.stdout
    send = transport or send_via_smtp
    args = parse_args(argv)

    blank = [
        name
        for name, value in (
            ("--app-version", args.app_version),
            ("--build-number", args.build_number),
            ("--commit", args.commit),
            ("--repository", args.repository),
        )
        if not value.strip()
    ]
    if blank:
        # An empty dart-define or a skipped identity step would otherwise mail
        # testers "Tail End Charlie  (build )".
        stream.write(
            "::error::Tester notification not sent: no value for " + ", ".join(blank) + ".\n"
        )
        return 0

    context = ReleaseContext(
        track=args.track,
        app_version=args.app_version,
        build_number=args.build_number,
        commit=args.commit,
        repository=args.repository,
        run_url=args.run_url,
        changes=read_changes(args.changes_file),
        changes_baseline=args.changes_baseline,
    )
    icon = load_mail_icon()
    try:
        email = render_email(context, with_icon=icon is not None)
    except UnsafeContentError as error:
        stream.write(f"::error::Tester notification not sent: {error}\n")
        return 0

    settings, missing = smtp_settings(environment)
    decision = decide(args.mode, args.recipient, missing)
    delivered = False
    if decision.action == "send" and settings is not None:
        message = build_message(email, settings.sender, args.recipient.strip(), icon=icon)
        try:
            send(message, settings)
            delivered = True
        # Deliberately broad: every SMTP, TLS, DNS and socket failure has to end
        # as a loud annotation rather than a failed release.
        except Exception as error:
            stream.write(
                "::error::Tester notification could not be delivered: "
                f"{type(error).__name__}: {error}\n"
            )

    _write_summary(
        environment,
        summary_markdown(email, decision, args.recipient, delivered),
        stream,
    )
    if delivered:
        stream.write(f"::notice::Tester notification sent to {mask_recipient(args.recipient)}.\n")
    elif decision.action != "send":
        stream.write(f"::notice::Tester notification {decision.action}: {decision.reason}\n")
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    raise SystemExit(main(sys.argv[1:]))
