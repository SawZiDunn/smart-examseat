#!/usr/bin/env python3
"""
export.py - CSV and PDF output for a finished seating plan (Member C).

    seating_csv(report)                -> str   (full plan, one row per seat)
    room_list_csv(report)              -> str   (one row per room, summary)
    seating_pdf(report, layouts)       -> bytes (per-room grids + name lists)

`report` is whatever bridge.SeatingEngine.generate() returned.
`layouts` maps room_id -> the dict returned by SeatingEngine.room_layout().
"""

from __future__ import annotations

import csv
import io
from datetime import datetime

CSV_COLUMNS = [
    "session", "exam", "room", "row", "col",
    "student_id", "student_name", "major", "year", "seat_type",
]


# ---------------------------------------------------------------------------
# CSV
# ---------------------------------------------------------------------------

def seating_csv(report: dict, layouts: dict | None = None) -> str:
    """The whole seating plan as CSV, sorted by room then seat."""
    layouts = layouts or {}
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(CSV_COLUMNS)

    rows = sorted(report["assignments"], key=lambda a: (a.room, a.row, a.col))
    for a in rows:
        writer.writerow([
            report["session"], a.exam, a.room, a.row, a.col,
            a.student, a.name, a.major.upper(), a.year,
            _seat_type(layouts, a.room, a.row, a.col),
        ])
    return buffer.getvalue()


def room_list_csv(report: dict) -> str:
    """One summary row per room: headcount and the exams sitting in it."""
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(["session", "room", "students", "exams"])
    for room_id in sorted(report["rooms"]):
        seats = report["rooms"][room_id]
        exams = sorted({a.exam for a in seats})
        writer.writerow([report["session"], room_id, len(seats),
                         " ".join(exams)])
    return buffer.getvalue()


def _seat_type(layouts: dict, room: str, row: int, col: int) -> str:
    layout = layouts.get(room)
    if not layout:
        return ""
    for seat in layout["seats"]:
        if seat["row"] == row and seat["col"] == col:
            return seat["type"]
    return ""


# ---------------------------------------------------------------------------
# PDF
# ---------------------------------------------------------------------------

def seating_pdf(report: dict, layouts: dict, session_info: dict | None = None,
                rooms: list | None = None) -> bytes:
    """Per-room seat layout plus the student list, one room per page."""
    try:
        from reportlab.lib import colors
        from reportlab.lib.pagesizes import A4, landscape
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.lib.units import mm
        from reportlab.platypus import (SimpleDocTemplate, Table, TableStyle,
                                        Paragraph, Spacer, PageBreak)
    except ImportError as exc:                           # pragma: no cover
        raise RuntimeError(
            "reportlab is not installed. Run: pip install reportlab") from exc

    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer, pagesize=landscape(A4),
        leftMargin=12 * mm, rightMargin=12 * mm,
        topMargin=12 * mm, bottomMargin=12 * mm,
        title=f"SmartExamSeat - {report['session']}")

    styles = getSampleStyleSheet()
    h1 = ParagraphStyle("h1", parent=styles["Heading1"], fontSize=16,
                        spaceAfter=4)
    h2 = ParagraphStyle("h2", parent=styles["Heading2"], fontSize=12,
                        spaceBefore=8, spaceAfter=4)
    small = ParagraphStyle("small", parent=styles["Normal"], fontSize=8,
                           textColor=colors.HexColor("#555555"))

    story = []
    story.extend(_cover(report, session_info, h1, small, styles, colors, Table,
                        TableStyle, Paragraph, Spacer, mm))

    wanted = rooms or sorted(report["rooms"])
    for room_id in wanted:
        seats = report["rooms"].get(room_id)
        if not seats:
            continue
        story.append(PageBreak())
        story.append(Paragraph(
            f"Room {room_id} &mdash; session {report['session']}", h1))
        layout = layouts.get(room_id, {})
        story.append(Paragraph(
            f"{len(seats)} students &bull; "
            f"{layout.get('rows', '?')} rows &times; "
            f"{layout.get('cols', '?')} columns &bull; "
            f"exams: {', '.join(sorted({a.exam for a in seats}))}", small))
        story.append(Spacer(1, 6))
        story.append(_grid_table(room_id, seats, layout, colors, Table,
                                 TableStyle, mm))
        story.append(Paragraph("Student list", h2))
        story.append(_student_table(seats, colors, Table, TableStyle))

    doc.build(story, onFirstPage=_footer, onLaterPages=_footer)
    return buffer.getvalue()


def _cover(report, session_info, h1, small, styles, colors, Table, TableStyle,
           Paragraph, Spacer, mm):
    stats = report.get("stats", {})
    validation = report.get("validation", {})
    out = [Paragraph("SmartExamSeat &mdash; exam seating plan", h1)]

    when = ""
    if session_info:
        when = (f"{session_info.get('date', '')} "
                f"{session_info.get('start', '')}&ndash;"
                f"{session_info.get('end', '')}")
    filters = report.get("filters", {})
    years = ", ".join(str(y) for y in filters.get("years", [])) or "all"
    majors = ", ".join(m.upper() for m in filters.get("majors", [])) or "all"

    out.append(Paragraph(
        f"Session <b>{report['session']}</b> {when} &bull; "
        f"years: {years} &bull; majors: {majors} &bull; "
        f"generated {datetime.now():%Y-%m-%d %H:%M}", small))
    out.append(Spacer(1, 8))

    rows = [["Students seated", "Rooms used", "Reallocations", "Solve time",
             "Validator"]]
    rows.append([
        str(stats.get("students", len(report["assignments"]))),
        str(len(report["rooms"])),
        str(stats.get("retries", 0)),
        f"{stats.get('millis', 0)} ms",
        validation.get("status", "not run"),
    ])
    table = Table(rows, hAlign="LEFT")
    table.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 9),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef1f6")),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#b8c0cc")),
        ("PADDING", (0, 0), (-1, -1), 5),
    ]))
    out.append(table)
    out.append(Spacer(1, 10))

    summary = [["Room", "Students", "Exams"]]
    for room_id in sorted(report["rooms"]):
        seats = report["rooms"][room_id]
        summary.append([room_id, str(len(seats)),
                        ", ".join(sorted({a.exam for a in seats}))])
    rooms_table = Table(summary, hAlign="LEFT", repeatRows=1)
    rooms_table.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 8.5),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef1f6")),
        ("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#c8cedb")),
        ("PADDING", (0, 0), (-1, -1), 4),
    ]))
    out.append(rooms_table)
    return out


def _grid_table(room_id, seats, layout, colors, Table, TableStyle, mm):
    """The seat map: one cell per seat, student id + short name."""
    rows = layout.get("rows") or max(a.row for a in seats)
    cols = layout.get("cols") or max(a.col for a in seats)
    taken = {(a.row, a.col): a for a in seats}
    types = {(s["row"], s["col"]): s["type"] for s in layout.get("seats", [])}

    header = [""] + [f"C{c}" for c in range(1, cols + 1)]
    data = [header]
    style = [
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTNAME", (0, 0), (0, -1), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 6),
        ("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#c8cedb")),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (0, 0), (-1, -1), "CENTER"),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef1f6")),
        ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#eef1f6")),
    ]

    exams = sorted({a.exam for a in seats})
    palette = [colors.HexColor(h) for h in
               ("#dbeafe", "#dcfce7", "#fef3c7", "#fae8ff", "#ffe4e6",
                "#e0f2fe", "#ede9fe", "#ecfccb")]
    exam_color = {e: palette[i % len(palette)] for i, e in enumerate(exams)}

    for r in range(1, rows + 1):
        line = [f"R{r}"]
        for c in range(1, cols + 1):
            a = taken.get((r, c))
            if a:
                line.append(f"{a.student}\n{_short(a.name)}")
                style.append(("BACKGROUND", (c, r), (c, r),
                              exam_color[a.exam]))
            else:
                line.append("·")
                if types.get((r, c)) == "accessible":
                    style.append(("BACKGROUND", (c, r), (c, r),
                                  colors.HexColor("#f1f5f9")))
                style.append(("TEXTCOLOR", (c, r), (c, r),
                              colors.HexColor("#9aa3b2")))
        data.append(line)

    width = min(260 * mm / max(cols + 1, 1), 22 * mm)
    table = Table(data, colWidths=[10 * mm] + [width] * cols, hAlign="LEFT")
    table.setStyle(TableStyle(style))
    return table


def _student_table(seats, colors, Table, TableStyle):
    """Alphabetical name list with each student's seat, in three columns."""
    ordered = sorted(seats, key=lambda a: (a.name or a.student, a.student))
    cells = [[a.student, _short(a.name, 22), a.exam, f"R{a.row}C{a.col}"]
             for a in ordered]

    per_col = (len(cells) + 2) // 3 or 1
    chunks = [cells[i:i + per_col] for i in range(0, len(cells), per_col)]
    while len(chunks) < 3:
        chunks.append([])
    height = max(len(c) for c in chunks)

    header = ["ID", "Name", "Exam", "Seat"] * 3
    data = [header]
    for i in range(height):
        line = []
        for chunk in chunks:
            line.extend(chunk[i] if i < len(chunk) else ["", "", "", ""])
        data.append(line)

    table = Table(data, repeatRows=1, hAlign="LEFT")
    table.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 6.5),
        ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#d7dce6")),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef1f6")),
        ("PADDING", (0, 0), (-1, -1), 2),
    ]))
    return table


def _short(text: str, limit: int = 14) -> str:
    text = text or ""
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 7)
    canvas.setFillGray(0.45)
    canvas.drawRightString(doc.pagesize[0] - 12 * 2.83465, 8 * 2.83465,
                           f"SmartExamSeat  -  page {doc.page}")
    canvas.restoreState()
