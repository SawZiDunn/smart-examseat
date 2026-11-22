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
"""

from __future__ import annotations

import datetime
import io
import re

from openpyxl import load_workbook

import generate_data
from generate_data import Dataset, GenerationError

ACCESS = ("none", "wheelchair", "other_accessible")
DEFAULT_FILL = 80
DEFAULT_ACC_COLS = [1, 3, 5, 7]


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
    return generate_data.sessions_from(start.isoformat(), days, slots) if slots else []


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
