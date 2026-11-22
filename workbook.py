#!/usr/bin/env python3
"""
SmartExamSeat - the dataset workbook (.xlsx).

The administrator describes the term in one Excel workbook:

    Summary       students / subjects / accessible students per (major, year),
                  worked out by Excel formulas from the sheets below. Read
                  only: the app ignores it.
    Students      Student ID | Name | Major | Year | Access
    Subjects      Code | Major | Year
    Rooms         Room ID | Rows | Columns | Seats | Available
    Exam period   first exam day, exam days, morning and afternoon slot
    Settings      session fill %, accessible front-row columns

Every student sits every subject of their own (major, year) cohort, so there
is no enrolment sheet. read_workbook() turns the workbook into the Dataset of
generate_data.py; generate_from_workbook() then runs the Prolog timetabler on
it, exactly like `make data`.

write_workbook() goes the other way. It is how datasets/big.xlsx and
datasets/small.xlsx are made from the random-roster recipes
(datasets/*.toml):

    python3 workbook.py datasets/big.toml datasets/big.xlsx
"""

from __future__ import annotations

import datetime
import io
import os
import re
import sys

from openpyxl import Workbook, load_workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation

import generate_data
from generate_data import Dataset, GenerationError

ACCESS = ("none", "wheelchair", "other_accessible")
DEFAULT_FILL = 80
DEFAULT_ACC_COLS = [1, 3, 5, 7]
MAX_ROWS = 20000           # for the Summary formulas' ranges

HEAD_FONT = Font(bold=True, color="FFFFFF")
HEAD_FILL = PatternFill("solid", fgColor="2F6FED")
NOTE_FONT = Font(italic=True, color="666666")
TITLE_FONT = Font(bold=True, size=14)


class WorkbookError(GenerationError):
    """The workbook is wrong; the message names the sheet and row."""


# ==========================================================================
# Reading
# ==========================================================================

def read_workbook(source) -> tuple:
    """A path, bytes or file object -> (Dataset without exams, fill %).

    Raises WorkbookError listing up to 15 problems, each with sheet and row.
    """
    if isinstance(source, (bytes, bytearray)):
        source = io.BytesIO(source)
    try:
        wb = load_workbook(source, data_only=True, read_only=True)
    except Exception as exc:                      # zip / xml errors
        raise WorkbookError(f"Not a readable .xlsx workbook ({exc}).") from exc

    problems: list = []
    ds = Dataset()
    try:
        period = key_values(wb, "Exam period", problems)
        settings = key_values(wb, "Settings", problems)
        fill = whole(settings.get("session fill %", DEFAULT_FILL),
                     "Settings", "Session fill %", problems, 1, 100)
        acc_cols = columns_list(settings.get("accessible front-row columns",
                                             ", ".join(map(str, DEFAULT_ACC_COLS))),
                                problems)
        ds.sessions = read_sessions(period, problems)
        ds.rooms, ds.seats = read_rooms(wb, acc_cols, problems)
        read_people(wb, ds, problems)
    finally:
        wb.close()

    if problems:
        shown = problems[:15]
        more = len(problems) - len(shown)
        raise WorkbookError("The workbook has problems:\n- " + "\n- ".join(shown)
                            + (f"\n- ... and {more} more" if more else ""))
    return ds, fill


def generate_from_workbook(source, verbose: bool = False) -> tuple:
    """Workbook -> (Dataset with its timetable, timetable summary line)."""
    ds, fill = read_workbook(source)
    ds.exams, summary = generate_data.run_timetabler(ds, fill)
    try:
        generate_data.check_and_report(ds, "dataset", verbose)
    except AssertionError as exc:
        raise GenerationError(str(exc)) from exc
    return ds, summary


# --- sheet helpers --------------------------------------------------------

def sheet(wb, name: str, problems: list):
    for ws in wb.worksheets:
        if ws.title.strip().lower() == name.lower():
            return ws
    problems.append(f"There is no '{name}' sheet.")
    return None


def table(wb, name: str, columns: list, problems: list) -> list:
    """The rows of a table sheet as (row number, {column: value}).

    Columns are found by their header (any order, any case); blank rows are
    skipped.
    """
    ws = sheet(wb, name, problems)
    if ws is None:
        return []
    rows = ws.iter_rows(values_only=True)
    header = next(rows, None) or ()
    index = {str(h).strip().lower(): i for i, h in enumerate(header) if h is not None}
    missing = [c for c in columns if c.lower() not in index]
    if missing:
        problems.append(f"{name}: the first row must have the column(s) "
                        f"{', '.join(missing)}.")
        return []
    out = []
    for n, row in enumerate(rows, start=2):
        values = {c: clean(row[index[c.lower()]]) if index[c.lower()] < len(row) else None
                  for c in columns}
        if all(v is None for v in values.values()):
            continue
        out.append((n, values))
    return out


def key_values(wb, name: str, problems: list) -> dict:
    """A two-column sheet (label | value) as {lowercase label: value}."""
    ws = sheet(wb, name, problems)
    if ws is None:
        return {}
    out = {}
    for row in ws.iter_rows(values_only=True):
        if row and row[0] is not None and len(row) > 1:
            out[str(row[0]).strip().lower()] = clean(row[1])
    return out


def clean(value):
    if isinstance(value, str):
        value = value.strip()
        return value or None
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def whole(value, where: str, what: str, problems: list, lo=None, hi=None):
    if isinstance(value, str) and re.fullmatch(r"\d+", value):
        value = int(value)
    if not isinstance(value, int) or isinstance(value, bool) \
            or (lo is not None and value < lo) or (hi is not None and value > hi):
        rng = f" ({lo}-{hi})" if lo is not None and hi is not None else ""
        problems.append(f"{where}: {what} must be a whole number{rng}, got {value!r}.")
        return lo or 0
    return value


def code(value) -> str | None:
    """IDs and codes as text; 67011653 typed as a number stays 67011653."""
    if value is None:
        return None
    return str(value).strip().lower()


def ident_ok(text: str) -> bool:
    return bool(re.fullmatch(r"[a-z0-9][a-z0-9_.-]*", text))


def as_time(value) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime.datetime):
        value = value.time()
    if isinstance(value, datetime.time):
        return value.strftime("%H:%M")
    if isinstance(value, (int, float)) and 0 <= value < 1:      # Excel day fraction
        minutes = round(value * 24 * 60)
        return f"{minutes // 60:02d}:{minutes % 60:02d}"
    m = re.fullmatch(r"(\d{1,2})[:.](\d{2})", str(value).strip())
    if m and int(m.group(1)) < 24 and int(m.group(2)) < 60:
        return f"{int(m.group(1)):02d}:{m.group(2)}"
    return "bad"


def as_date(value) -> datetime.date | None:
    if isinstance(value, datetime.datetime):
        return value.date()
    if isinstance(value, datetime.date):
        return value
    try:
        return datetime.date.fromisoformat(str(value).strip())
    except ValueError:
        return None


def columns_list(value, problems: list) -> list:
    if isinstance(value, int):
        return [value]
    parts = [p for p in re.split(r"[,\s]+", str(value or "")) if p]
    if not parts or not all(p.isdigit() and int(p) > 0 for p in parts):
        problems.append("Settings: Accessible front-row columns must look like "
                        f"'1, 3, 5, 7', got {value!r}.")
        return DEFAULT_ACC_COLS
    return sorted({int(p) for p in parts})


# --- the sheets -----------------------------------------------------------

def read_sessions(period: dict, problems: list) -> list:
    start = as_date(period.get("first exam day"))
    if start is None:
        problems.append("Exam period: First exam day must be a date like 2026-12-01.")
        start = datetime.date(2026, 12, 1)
    days = whole(period.get("exam days"), "Exam period", "Exam days", problems, 1, 60)
    slots = []
    for part in ("morning", "afternoon"):
        st, en = (as_time(period.get(f"{part} starts")),
                  as_time(period.get(f"{part} ends")))
        if st is None and en is None:
            continue
        if "bad" in (st, en) or st is None or en is None or st >= en:
            problems.append(f"Exam period: the {part} slot needs a start and an end "
                            f"time like 09:30 and 12:30, the end after the start.")
            continue
        slots.append([st, en])
    if not slots:
        problems.append("Exam period: give at least the morning slot.")
    elif len(slots) == 2 and slots[1][0] < slots[0][1]:
        problems.append("Exam period: the afternoon slot must start after the "
                        "morning slot ends.")
    cfg = {"exam_period": {"start_date": start.isoformat(), "days": days,
                           "slots": slots}}
    return generate_data.sessions_from(cfg) if slots else []


def read_rooms(wb, acc_cols: list, problems: list) -> tuple:
    rooms, seats, seen = [], [], set()
    for n, r in table(wb, "Rooms", ["Room ID", "Rows", "Columns", "Available"], problems):
        rid = code(r["Room ID"])
        where = f"Rooms row {n}"
        if not rid or not ident_ok(rid):
            problems.append(f"{where}: Room ID {r['Room ID']!r} must be letters and "
                            "digits, e.g. r101.")
            continue
        if rid in seen:
            problems.append(f"{where}: room {rid} is listed twice.")
            continue
        seen.add(rid)
        rows = whole(r["Rows"], where, "Rows", problems, 1, 40)
        cols = whole(r["Columns"], where, "Columns", problems, 1, 40)
        avail = str(r["Available"] if r["Available"] is not None else "yes").lower()
        if avail in ("true", "1"):
            avail = "yes"
        if avail in ("false", "0"):
            avail = "no"
        if avail not in ("yes", "no"):
            problems.append(f"{where}: Available must be yes or no, got {r['Available']!r}.")
            continue
        rooms.append((rid, rows, cols, avail))
        for row in range(1, rows + 1):
            for col in range(1, cols + 1):
                kind = "accessible" if row == 1 and col in acc_cols else "normal"
                seats.append((rid, row, col, kind))
    if not rooms and not any(p.startswith("Rooms") for p in problems):
        problems.append("Rooms: list at least one room.")
    return rooms, seats


def read_people(wb, ds: Dataset, problems: list) -> None:
    cohorts: dict = {}                        # (major, year) -> [student ids]
    seen = set()
    for n, r in table(wb, "Students", ["Student ID", "Name", "Major", "Year", "Access"],
                      problems):
        where = f"Students row {n}"
        sid, major = code(r["Student ID"]), code(r["Major"])
        if not sid or not ident_ok(sid):
            problems.append(f"{where}: Student ID {r['Student ID']!r} must be letters "
                            "and digits, e.g. 67011653.")
            continue
        if sid in seen:
            problems.append(f"{where}: student {sid} is listed twice.")
            continue
        seen.add(sid)
        if not major or not re.fullmatch(r"[a-z][a-z0-9_]*", major):
            problems.append(f"{where}: Major {r['Major']!r} must be a code like SE.")
            continue
        year = whole(r["Year"], where, "Year", problems, 1, 8)
        access = code(r["Access"]) or "none"
        if access not in ACCESS:
            problems.append(f"{where}: Access must be none, wheelchair or "
                            f"other_accessible, got {r['Access']!r}.")
            continue
        ds.students.append((sid, major, year, access))
        ds.names.append((sid, str(r["Name"]) if r["Name"] is not None else sid.upper()))
        cohorts.setdefault((major, year), []).append(sid)
    if not ds.students and not any(p.startswith("Students") for p in problems):
        problems.append("Students: list at least one student.")

    subjects: dict = {}                       # (major, year) -> [codes]
    seen = set()
    for n, r in table(wb, "Subjects", ["Code", "Major", "Year"], problems):
        where = f"Subjects row {n}"
        c, major = code(r["Code"]), code(r["Major"])
        if not c or not ident_ok(c):
            problems.append(f"{where}: Code {r['Code']!r} must be letters and digits, "
                            "e.g. se101.")
            continue
        if c in seen:
            problems.append(f"{where}: subject {c} is listed twice.")
            continue
        seen.add(c)
        year = whole(r["Year"], where, "Year", problems, 1, 8)
        if (major, year) not in cohorts:
            problems.append(f"{where}: {c} is for {str(major).upper()} year {year}, "
                            "but no student is in that major and year.")
            continue
        subjects.setdefault((major, year), []).append(c)
        ds.subjects.append(c)

    for sid, major, year, _ in ds.students:
        for c in subjects.get((major, year), []):
            ds.enrolments.append((sid, c))


# ==========================================================================
# Writing
# ==========================================================================

def write_workbook(ds: Dataset, path: str, title: str,
                   fill: int = DEFAULT_FILL, acc_cols=None) -> None:
    """Dataset -> a workbook in the format read_workbook() reads."""
    acc_cols = acc_cols or DEFAULT_ACC_COLS
    cohort_of = {s[0]: (s[1], s[2]) for s in ds.students}
    subject_cohort = {}
    for sid, c in ds.enrolments:
        subject_cohort.setdefault(c, cohort_of[sid])
    cohorts = list(dict.fromkeys((s[1], s[2]) for s in ds.students))

    wb = Workbook()
    summary = wb.active
    summary.title = "Summary"

    # --- Students
    ws = wb.create_sheet("Students")
    header(ws, ["Student ID", "Name", "Major", "Year", "Access"], [14, 24, 9, 7, 18])
    names = dict(ds.names)
    for sid, major, year, access in ds.students:
        ws.append([sid, names.get(sid, ""), major.upper(), year, access])
    dropdown(ws, "E", '"none,wheelchair,other_accessible"')

    # --- Subjects
    ws = wb.create_sheet("Subjects")
    header(ws, ["Code", "Major", "Year"], [12, 9, 7])
    for c in ds.subjects:
        major, year = subject_cohort[c]
        ws.append([c, major.upper(), year])

    # --- Rooms
    ws = wb.create_sheet("Rooms")
    header(ws, ["Room ID", "Rows", "Columns", "Seats", "Available"], [10, 7, 9, 8, 10])
    for i, (rid, rows, cols, avail) in enumerate(ds.rooms, start=2):
        ws.append([rid, rows, cols, f"=B{i}*C{i}", avail])
    dropdown(ws, "E", '"yes,no"')

    # --- Exam period
    ws = wb.create_sheet("Exam period")
    dates = sorted({s[1] for s in ds.sessions})
    slots = sorted({(s[2], s[3]) for s in ds.sessions})
    morning = slots[0] if slots else ("09:30", "12:30")
    afternoon = slots[1] if len(slots) > 1 else (None, None)
    rows = [("First exam day", datetime.date.fromisoformat(dates[0]) if dates
             else datetime.date(2026, 12, 1), "weekends are skipped"),
            ("Exam days", len(dates), "working days in the exam period"),
            ("Morning starts", morning[0], "HH:MM"),
            ("Morning ends", morning[1], ""),
            ("Afternoon starts", afternoon[0], "leave both afternoon cells empty "
                                               "for mornings only"),
            ("Afternoon ends", afternoon[1], ""),
            ("Sessions", "=B3*IF(B6=\"\",1,2)", "worked out: exam days x slots a day")]
    key_value_sheet(ws, rows)
    ws["B2"].number_format = "yyyy-mm-dd"
    for cell in ("B4", "B5", "B6", "B7"):
        ws[cell].number_format = "@"

    # --- Settings
    ws = wb.create_sheet("Settings")
    key_value_sheet(ws, [
        ("Session fill %", fill,
         "a session may use at most this share of the open seats (leaves room "
         "for students of one exam to sit apart)"),
        ("Accessible front-row columns", ", ".join(map(str, acc_cols)),
         "front-row seats in these columns are accessible seats, in every room"),
    ])

    # --- Summary (formulas over the sheets above)
    write_summary(summary, title, cohorts)
    wb.save(path)


def header(ws, names: list, widths: list) -> None:
    ws.append(names)
    for i, (name, w) in enumerate(zip(names, widths), start=1):
        cell = ws.cell(row=1, column=i)
        cell.font, cell.fill = HEAD_FONT, HEAD_FILL
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = "A2"


def key_value_sheet(ws, rows: list) -> None:
    header(ws, ["Setting", "Value", "Notes"], [30, 14, 70])
    for label, value, note in rows:
        ws.append([label, value, note])
        ws.cell(row=ws.max_row, column=3).font = NOTE_FONT
        ws.cell(row=ws.max_row, column=2).alignment = Alignment(horizontal="left")


def dropdown(ws, col: str, choices: str) -> None:
    dv = DataValidation(type="list", formula1=choices, allow_blank=True)
    ws.add_data_validation(dv)
    dv.add(f"{col}2:{col}{MAX_ROWS}")


def write_summary(ws, title: str, cohorts: list) -> None:
    n = MAX_ROWS
    st = {k: f"Students!${c}$2:${c}${n}" for k, c in
          (("major", "C"), ("year", "D"), ("access", "E"))}
    sb = {k: f"Subjects!${c}$2:${c}${n}" for k, c in (("major", "B"), ("year", "C"))}

    ws["A1"] = title
    ws["A1"].font = TITLE_FONT
    ws["A2"] = ("Worked out from the other sheets - edit Students, Subjects, Rooms, "
                "Exam period and Settings, not this one. Every student sits every "
                "subject of their major and year.")
    ws["A2"].font = NOTE_FONT

    top = 4
    names = ["Major", "Year", "Students", "Subjects", "Accessible", "Exam seats"]
    for i, name in enumerate(names, start=1):
        cell = ws.cell(row=top, column=i, value=name)
        cell.font, cell.fill = HEAD_FONT, HEAD_FILL
    for i, w in enumerate([10, 7, 10, 10, 11, 11, 4, 22, 12], start=1):
        ws.column_dimensions[get_column_letter(i)].width = w

    r = top
    order = {m: i for i, m in enumerate(dict.fromkeys(m for m, _ in cohorts))}
    for major, year in sorted(cohorts, key=lambda c: (c[1], order[c[0]])):
        r += 1
        ws.cell(row=r, column=1, value=major.upper())
        ws.cell(row=r, column=2, value=year)
        ws.cell(row=r, column=3,
                value=f"=COUNTIFS({st['major']},A{r},{st['year']},B{r})")
        ws.cell(row=r, column=4,
                value=f"=COUNTIFS({sb['major']},A{r},{sb['year']},B{r})")
        ws.cell(row=r, column=5,
                value=f"=COUNTIFS({st['major']},A{r},{st['year']},B{r},"
                      f"{st['access']},\"<>none\")")
        ws.cell(row=r, column=6, value=f"=C{r}*D{r}")
    r += 1
    ws.cell(row=r, column=1, value="Total").font = Font(bold=True)
    for col in "CDEF":
        cell = ws[f"{col}{r}"]
        cell.value = f"=SUM({col}{top + 1}:{col}{r - 1})"
        cell.font = Font(bold=True)

    # resources, beside the cohort table
    rooms = f"Rooms!$E$2:$E${n}"
    rows = [("Resources", None),
            ("Rooms open", f"=COUNTIF({rooms},\"yes\")"),
            ("Rooms closed", f"=COUNTIF({rooms},\"no\")"),
            ("Seats in open rooms", f"=SUMIF({rooms},\"yes\",Rooms!$D$2:$D${n})"),
            ("Exam days", "='Exam period'!B3"),
            ("Sessions", "='Exam period'!B8"),
            ("Session fill %", "=Settings!B2")]
    for i, (label, formula) in enumerate(rows):
        a = ws.cell(row=top + i, column=8, value=label)
        if formula is None:
            a.font, a.fill = HEAD_FONT, HEAD_FILL
            ws.cell(row=top + i, column=9).fill = HEAD_FILL
        else:
            ws.cell(row=top + i, column=9, value=formula)
    ws.freeze_panes = f"A{top + 1}"


# ==========================================================================
# Command line: recipe (.toml) -> workbook
# ==========================================================================

def workbook_from_recipe(recipe: str, out: str) -> None:
    cfg = generate_data.load_config(recipe)
    ds = generate_data.build_full(cfg)
    title = cfg.get("title", f"SmartExamSeat dataset ({os.path.basename(recipe)})")
    write_workbook(ds, out, title,
                   fill=cfg.get("timetable", {}).get("max_fill_percent", DEFAULT_FILL),
                   acc_cols=cfg.get("rooms", {}).get("accessible_front_cols"))
    print(f"wrote {out}: {len(ds.students)} students, {len(ds.subjects)} subjects, "
          f"{len(ds.rooms)} rooms, {len(ds.sessions)} sessions")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: python3 workbook.py RECIPE.toml OUT.xlsx")
    workbook_from_recipe(sys.argv[1], sys.argv[2])
