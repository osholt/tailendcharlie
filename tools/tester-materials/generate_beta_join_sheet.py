#!/usr/bin/env python3
"""Generate the print-ready Tail End Charlie closed-beta joining sheet."""

from __future__ import annotations

import argparse
from pathlib import Path

from reportlab.graphics import renderPDF
from reportlab.graphics.barcode.qr import QrCodeWidget
from reportlab.graphics.shapes import Drawing
from reportlab.lib.colors import Color, HexColor, white
from reportlab.lib.pagesizes import A4
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.pdfgen.canvas import Canvas


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "output/pdf/tail-end-charlie-beta-join-a4.pdf"
TMP = ROOT / "tmp/pdfs"
LOGO = ROOT / "apps/mobile/assets/branding/ride-relay-app-icon-master.png"

IOS_URL = "https://testflight.apple.com/join/HHa3BvtW"
ANDROID_GROUP_URL = "https://groups.google.com/g/tail-end-charlie-testers"
ANDROID_PLAY_URL = "https://play.google.com/apps/testing/app.tailendcharlie"

NAVY = HexColor("#152331")
INK = HexColor("#15202B")
MUTED = HexColor("#51606D")
TEAL = HexColor("#31B8A3")
ORANGE = HexColor("#F28C52")
PALE_BLUE = HexColor("#EAF3F6")
PALE_ORANGE = HexColor("#FFF0E7")
PALE_GREEN = HexColor("#EAF7F3")
PAPER = HexColor("#FAF8F4")
LINE = HexColor("#D7DFE4")


def rounded_card(
    canvas: Canvas,
    x: float,
    y: float,
    width: float,
    height: float,
    fill: Color,
) -> None:
    canvas.setFillColor(fill)
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.8)
    canvas.roundRect(x, y, width, height, 12, fill=1, stroke=1)


def number_badge(canvas: Canvas, number: str, x: float, y: float, fill: Color) -> None:
    canvas.setFillColor(fill)
    canvas.circle(x, y, 14, fill=1, stroke=0)
    canvas.setFillColor(white)
    canvas.setFont("Helvetica-Bold", 14)
    canvas.drawCentredString(x, y - 5, number)


def wrap_lines(text: str, font: str, size: float, max_width: float) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = word if not current else f"{current} {word}"
        if stringWidth(candidate, font, size) <= max_width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def paragraph(
    canvas: Canvas,
    text: str,
    x: float,
    y: float,
    max_width: float,
    *,
    font: str = "Helvetica",
    size: float = 10.2,
    leading: float = 13.5,
    color: Color = INK,
) -> float:
    canvas.setFillColor(color)
    canvas.setFont(font, size)
    cursor = y
    for line in wrap_lines(text, font, size, max_width):
        canvas.drawString(x, cursor, line)
        cursor -= leading
    return cursor


def numbered_step(
    canvas: Canvas,
    number: int,
    text: str,
    x: float,
    y: float,
    max_width: float,
) -> float:
    canvas.setFillColor(INK)
    canvas.setFont("Helvetica-Bold", 10.5)
    canvas.drawString(x, y, f"{number}.")
    return paragraph(canvas, text, x + 17, y, max_width - 17, leading=13.2)


def draw_qr(
    canvas: Canvas,
    url: str,
    x: float,
    y: float,
    size: float,
    label: str,
    caption: str,
) -> None:
    canvas.setFillColor(white)
    canvas.roundRect(x - 4, y - 4, size + 8, size + 8, 7, fill=1, stroke=0)
    widget = QrCodeWidget(url, barLevel="H", barFillColor=NAVY)
    x1, y1, x2, y2 = widget.getBounds()
    drawing = Drawing(
        size, size, transform=[size / (x2 - x1), 0, 0, size / (y2 - y1), 0, 0]
    )
    drawing.add(widget)
    renderPDF.draw(drawing, canvas, x, y)
    canvas.setFillColor(INK)
    canvas.setFont("Helvetica-Bold", 9.2)
    canvas.drawCentredString(x + size / 2, y - 17, label)
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica", 7.6)
    canvas.drawCentredString(x + size / 2, y - 29, caption)


def build(*, whatsapp_url: str) -> Path:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)

    width, height = A4
    canvas = Canvas(str(OUTPUT), pagesize=A4, pageCompression=1)
    canvas.setTitle("Join the Tail End Charlie closed beta")
    canvas.setAuthor("Tail End Charlie")

    canvas.setFillColor(PAPER)
    canvas.rect(0, 0, width, height, fill=1, stroke=0)

    # Header
    canvas.setFillColor(NAVY)
    canvas.rect(0, height - 102, width, 102, fill=1, stroke=0)
    canvas.drawImage(
        ImageReader(LOGO),
        28,
        height - 87,
        66,
        66,
        preserveAspectRatio=True,
        mask="auto",
    )
    canvas.setFillColor(white)
    canvas.setFont("Helvetica-Bold", 23)
    canvas.drawString(112, height - 48, "TAIL END CHARLIE")
    canvas.setFont("Helvetica-Bold", 13)
    canvas.setFillColor(HexColor("#DCE8EC"))
    canvas.drawString(112, height - 72, "JOIN THE CLOSED BETA")

    canvas.setFillColor(INK)
    canvas.setFont("Helvetica-Bold", 13)
    canvas.drawString(
        28, height - 128, "Scan with the phone you will take on the ride."
    )
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica", 9.5)
    canvas.drawString(
        28,
        height - 145,
        "Use your normal Apple ID or Google account. Allow a few minutes for store access to update.",
    )

    # iPhone card
    card_x, card_w = 28, width - 56
    ios_y, ios_h = height - 327, 166
    rounded_card(canvas, card_x, ios_y, card_w, ios_h, PALE_BLUE)
    number_badge(canvas, "1", 52, ios_y + ios_h - 29, TEAL)
    canvas.setFillColor(INK)
    canvas.setFont("Helvetica-Bold", 16)
    canvas.drawString(75, ios_y + ios_h - 35, "iPHONE / iOS")
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica-Bold", 9)
    canvas.drawString(75, ios_y + ios_h - 51, "TESTFLIGHT BETA")

    step_y = ios_y + ios_h - 75
    step_y = numbered_step(
        canvas,
        1,
        "Scan the QR code with Camera.",
        48,
        step_y,
        330,
    )
    step_y = numbered_step(
        canvas,
        2,
        "If asked, install TestFlight from the App Store, then return to the link and tap Accept.",
        48,
        step_y - 4,
        330,
    )
    numbered_step(
        canvas,
        3,
        "Tap Install beside Tail End Charlie.",
        48,
        step_y - 4,
        330,
    )
    draw_qr(
        canvas,
        IOS_URL,
        425,
        ios_y + 34,
        112,
        "SCAN FOR iOS",
        "TestFlight invitation",
    )

    # Android card
    android_y, android_h = height - 580, 237
    rounded_card(canvas, card_x, android_y, card_w, android_h, PALE_ORANGE)
    number_badge(canvas, "2", 52, android_y + android_h - 29, ORANGE)
    canvas.setFillColor(INK)
    canvas.setFont("Helvetica-Bold", 16)
    canvas.drawString(75, android_y + android_h - 35, "ANDROID")
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica-Bold", 9)
    canvas.drawString(75, android_y + android_h - 51, "GOOGLE PLAY CLOSED TEST")

    step_y = android_y + android_h - 76
    step_y = numbered_step(
        canvas,
        1,
        "On your Android phone, sign in to the Google account you use for Google Play.",
        48,
        step_y,
        270,
    )
    step_y = numbered_step(
        canvas,
        2,
        "Scan A and request to join the tester group. Tell Oliver so he can approve you.",
        48,
        step_y - 4,
        270,
    )
    step_y = numbered_step(
        canvas,
        3,
        "After approval, scan B. Tap Become a tester, then follow the Google Play download link.",
        48,
        step_y - 4,
        270,
    )
    numbered_step(
        canvas,
        4,
        "Install or update Tail End Charlie in Google Play.",
        48,
        step_y - 4,
        270,
    )

    draw_qr(
        canvas,
        ANDROID_GROUP_URL,
        328,
        android_y + 68,
        92,
        "A  REQUEST ACCESS",
        "Google tester group",
    )
    draw_qr(
        canvas,
        ANDROID_PLAY_URL,
        452,
        android_y + 68,
        92,
        "B  INSTALL APP",
        "Google Play closed test",
    )
    paragraph(
        canvas,
        "If Play says you are not eligible, approval has not reached that Google account yet.",
        328,
        android_y + 27,
        215,
        font="Helvetica-Oblique",
        size=7.4,
        leading=9.2,
        color=MUTED,
    )

    # WhatsApp card
    whatsapp_y, whatsapp_h = 100, 146
    rounded_card(canvas, card_x, whatsapp_y, card_w, whatsapp_h, PALE_GREEN)
    number_badge(canvas, "3", 52, whatsapp_y + whatsapp_h - 29, TEAL)
    canvas.setFillColor(INK)
    canvas.setFont("Helvetica-Bold", 16)
    canvas.drawString(
        75, whatsapp_y + whatsapp_h - 35, "OPTIONAL: TESTER WHATSAPP GROUP"
    )
    paragraph(
        canvas,
        "Join for build updates, questions and feedback from other riders. Scan the code, open WhatsApp and tap Join group.",
        48,
        whatsapp_y + 78,
        340,
        size=10.4,
        leading=14,
    )
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica-Oblique", 8.5)
    canvas.drawString(
        48, whatsapp_y + 30, "You can test the app without joining WhatsApp."
    )
    draw_qr(
        canvas,
        whatsapp_url,
        425,
        whatsapp_y + 33,
        100,
        "SCAN FOR WHATSAPP",
        "Tail End Charlie testers",
    )

    # Footer
    canvas.setStrokeColor(LINE)
    canvas.line(28, 82, width - 28, 82)
    canvas.setFillColor(INK)
    canvas.setFont("Helvetica-Bold", 9.2)
    canvas.drawString(28, 64, "BEFORE THE RIDE:")
    canvas.setFont("Helvetica", 9.2)
    canvas.drawString(
        124,
        64,
        "Open the app once, finish setup and allow location access when the app asks.",
    )
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica", 7.5)
    canvas.drawCentredString(width / 2, 43, "tailendcharlie.app")

    canvas.showPage()
    canvas.save()
    return OUTPUT


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--whatsapp-url",
        required=True,
        help="Private invitation URL to encode; it is not stored in this repository.",
    )
    args = parser.parse_args()
    if not args.whatsapp_url.startswith("https://chat.whatsapp.com/"):
        parser.error("--whatsapp-url must be a WhatsApp group invitation URL")
    print(build(whatsapp_url=args.whatsapp_url))


if __name__ == "__main__":
    main()
