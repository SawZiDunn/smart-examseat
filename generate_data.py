#!/usr/bin/env python3
"""
SmartExamSeat - dataset generator (Member A).

Reads the dataset workbook (datasets/big.xlsx by default, see workbook.py)
and writes Prolog fact files that follow the schema in README.md section 8.2:

    student(Id, Major, Year, Access).
    student_name(Id, Name).
    subject(Code).
    enrolled(Id, Code).
    exam(Code, Session).
    session_time(Session, Date, Start, End).
    room(RoomId, Rows, Cols, Available).
    seat(RoomId, Row, Col, SeatType).

How the dataset is built:

    1. the workbook lists the students, each (major, year) cohort's OWN
       subjects, the rooms and the exam period; every student of a cohort is
       enrolled in all of its subjects;
    2. the exam timetable (exam/2: which session each subject is in) is found
       by the Prolog timetabling CSP in timetable.pl, which guarantees no
       student has two exams in one session and no session overflows.

Two datasets are produced:

    data_sample.pl   tiny smoke-test set  (20 students, 2 rooms, 1 session)
    data.pl          the dataset in the workbook

Usage:
    python3 generate_data.py                       # datasets/big.xlsx
    python3 generate_data.py --stats               # also print a capacity report
    python3 generate_data.py --workbook datasets/small.xlsx --out somewhere/
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN_PL = os.path.join(HERE, "main.pl")

# --------------------------------------------------------------------------
# model
# --------------------------------------------------------------------------

@dataclass
class Dataset:
    students: list = field(default_factory=list)      # (id, major, year, access)
    names: list = field(default_factory=list)         # (id, name)
    subjects: list = field(default_factory=list)      # code
    exams: list = field(default_factory=list)         # (code, session)
    enrolments: list = field(default_factory=list)    # (id, code)
    sessions: list = field(default_factory=list)      # (session, date, start, end)
    rooms: list = field(default_factory=list)         # (id, rows, cols, available)
    seats: list = field(default_factory=list)         # (room, row, col, type)


# --------------------------------------------------------------------------
# errors and sessions
# --------------------------------------------------------------------------

class GenerationError(Exception):
    """The dataset could not be built; the message says why in plain words."""


def sessions_from(start: str, days: int, slots: list) -> list:
    """One session per slot per weekday, from start ('2026-12-01'), weekends skipped."""
    day = datetime.date.fromisoformat(start)
    out, used = [], 0
    while used < days:
        if day.weekday() < 5:                       # Mon-Fri
            used += 1
            for slot_start, slot_end in slots:
                out.append((f"sess{len(out) + 1}", day.isoformat(), slot_start, slot_end))
        day += datetime.timedelta(days=1)
    return out


# --------------------------------------------------------------------------
# building
# --------------------------------------------------------------------------

def run_timetabler(ds: Dataset, fill: int) -> tuple:
    """Hand the dataset (without exams) to timetable.pl; return the exams."""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "untimetabled.pl")
        write_prolog(path, ds, "dataset awaiting a timetable")
        env = dict(os.environ, SMARTEXAMSEAT_DATA=path)
        try:
            proc = subprocess.run(
                ["swipl", "-q", "-g", f"timetable_cli([fill({int(fill)})])",
                 "-t", "halt", MAIN_PL],
                cwd=HERE, env=env, capture_output=True, text=True, timeout=600)
        except FileNotFoundError:
            raise GenerationError(
                "swipl not found - install SWI-Prolog (see requirements.txt)")

    exams, summary = [], ""
    for line in proc.stdout.splitlines():
        m = re.fullmatch(r"exam\((\w+|'(?:[^'\\]|\\.)*'), (\w+)\)\.", line.strip())
        if m:
            exams.append((unquote(m.group(1)), m.group(2)))
        elif line.startswith("% timetable:"):
            summary = line[2:]
        elif line.startswith("FAILED:"):
            raise GenerationError(
                f"timetabling failed: {line[len('FAILED:'):].strip()}")
    if proc.returncode != 0 or not exams and ds.subjects:
        raise GenerationError(f"timetabling failed (exit {proc.returncode}):\n"
                              f"{proc.stdout}\n{proc.stderr}")
    return exams, summary


def unquote(atom: str) -> str:
    """'se-101' -> se-101 (the reverse of q() for quoted atoms)."""
    if atom.startswith("'"):
        return re.sub(r"\\(.)", r"\1", atom[1:-1])
    return atom


def build_sample() -> Dataset:
    """Tiny hand-sized dataset: 20 students, 2 subjects, 1 session, 2 rooms."""
    ds = Dataset()
    ds.sessions = [("sess1", "2026-12-01", "09:30", "12:30")]
    ds.subjects = ["cs101", "ma201"]
    ds.exams = [("cs101", "sess1"), ("ma201", "sess1")]
    ds.rooms = [("r101", 4, 5, "yes"), ("r102", 3, 5, "yes")]
    for room_id, rows, cols, _ in ds.rooms:
        for row in range(1, rows + 1):
            for col in range(1, cols + 1):
                kind = "accessible" if row == 1 and col in (1, 3) else "normal"
                ds.seats.append((room_id, row, col, kind))

    names = [
        "Aung Hlaing", "Mya Oo", "Thandar Win", "Kyaw Htun", "Nilar Aye",
        "Zaw Naing", "Hnin Lin", "Soe Maung", "Ei Kyi", "Min Thu",
        "Thiri Swe", "Htet Mon", "Yadanar Nyein", "Phyo Sann", "Chan Htay",
        "Nay Phyu", "Su Zaw", "Wai Myint", "Kaung Tin", "May Latt",
    ]
    for i in range(1, 21):
        student_id = f"s{i:04d}"
        major = "se" if i % 2 else "cs"
        year = 1 if i <= 10 else 2
        access = "wheelchair" if i in (3, 14) else "none"
        ds.students.append((student_id, major, year, access))
        ds.names.append((student_id, names[i - 1]))
        ds.enrolments.append((student_id, "cs101" if i <= 10 else "ma201"))
    return ds


# --------------------------------------------------------------------------
# writing
# --------------------------------------------------------------------------

def q(value) -> str:
    """Render a Python value as a Prolog term."""
    if isinstance(value, int):
        return str(value)
    text = str(value)
    if text and text[0].islower() and all(c.isalnum() or c == "_" for c in text):
        return text
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"


def write_prolog(path: str, ds: Dataset, title: str) -> None:
    lines = [
        f"% {title}",
        "% GENERATED FILE - produced by generate_data.py, do not edit by hand.",
        "% Schema: README.md section 8.2.",
        "",
        ":- discontiguous student/4.",
        ":- discontiguous student_name/2.",
        ":- discontiguous subject/1.",
        ":- discontiguous enrolled/2.",
        ":- discontiguous exam/2.",
        ":- discontiguous session_time/4.",
        ":- discontiguous room/4.",
        ":- discontiguous seat/4.",
        ":- dynamic exam/2.",
        "",
    ]

    def block(header, rows, template):
        lines.append(f"% ---- {header} ({len(rows)}) ----")
        lines.extend(template(r) for r in rows)
        lines.append("")

    block("sessions", ds.sessions,
          lambda r: f"session_time({q(r[0])}, {q(r[1])}, {q(r[2])}, {q(r[3])}).")
    block("subjects", ds.subjects, lambda c: f"subject({q(c)}).")
    block("exams (timetable from timetable.pl)", ds.exams,
          lambda r: f"exam({q(r[0])}, {q(r[1])}).")
    block("rooms", ds.rooms,
          lambda r: f"room({q(r[0])}, {r[1]}, {r[2]}, {q(r[3])}).")
    block("seats", ds.seats,
          lambda r: f"seat({q(r[0])}, {r[1]}, {r[2]}, {q(r[3])}).")
    block("students", ds.students,
          lambda r: f"student({q(r[0])}, {q(r[1])}, {r[2]}, {q(r[3])}).")
    block("student names", ds.names,
          lambda r: f"student_name({q(r[0])}, {q(r[1])}).")
    block("enrolments", ds.enrolments,
          lambda r: f"enrolled({q(r[0])}, {q(r[1])}).")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


# --------------------------------------------------------------------------
# self-checks and reporting
# --------------------------------------------------------------------------

def check_and_report(ds: Dataset, label: str, verbose: bool) -> None:
    session_of = dict(ds.exams)
    missing = [c for c in ds.subjects if c not in session_of]
    assert not missing, f"{label}: subjects without an exam session: {missing[:5]}"

    # invariant 1: no student has two exams in one session
    seen = set()
    clashes = 0
    for student_id, code in ds.enrolments:
        key = (student_id, session_of[code])
        if key in seen:
            clashes += 1
        seen.add(key)
    assert clashes == 0, f"{label}: {clashes} exam clashes in generated data"

    # invariant 2: every session fits in the available rooms
    per_session, access_per_session = {}, {}
    access_of = {s[0]: s[3] for s in ds.students}
    for student_id, code in ds.enrolments:
        sess = session_of[code]
        per_session[sess] = per_session.get(sess, 0) + 1
        if access_of[student_id] != "none":
            access_per_session[sess] = access_per_session.get(sess, 0) + 1

    avail = {r[0] for r in ds.rooms if r[3] == "yes"}
    seats_total = sum(1 for s in ds.seats if s[0] in avail)
    access_total = sum(1 for s in ds.seats
                       if s[0] in avail and s[3] == "accessible")
    peak = max(per_session.values(), default=0)
    peak_access = max(access_per_session.values(), default=0)

    assert peak <= seats_total, (
        f"{label}: peak session has {peak} students but only "
        f"{seats_total} seats are available")
    assert peak_access <= access_total, (
        f"{label}: peak session needs {peak_access} accessible seats but only "
        f"{access_total} exist")

    if not verbose:
        return

    print(f"\n=== {label} ===")
    print(f"students          {len(ds.students)}")
    print(f"subjects          {len(ds.subjects)}")
    print(f"enrolments        {len(ds.enrolments)}")
    print(f"sessions          {len(ds.sessions)}")
    print(f"rooms             {len(ds.rooms)} "
          f"({len(avail)} available, {len(ds.rooms) - len(avail)} closed)")
    print(f"seats (available) {seats_total} "
          f"(of which accessible: {access_total})")
    print(f"exam clashes      {clashes}")
    print("\nper-session load:")
    print(f"  {'session':9} {'date':11} {'time':12} {'students':>9} "
          f"{'accessible':>11} {'exams':>6}")
    exams_per_session: dict = {}
    for code, sess in ds.exams:
        exams_per_session.setdefault(sess, []).append(code)
    for sess, date, start, end in ds.sessions:
        print(f"  {sess:9} {date:11} {start}-{end}  {per_session.get(sess, 0):>9} "
              f"{access_per_session.get(sess, 0):>11} "
              f"{len(exams_per_session.get(sess, [])):>6}")
    if seats_total:
        print(f"\npeak session load {peak} / {seats_total} seats "
              f"({100 * peak / seats_total:.0f}% occupancy)")


def main() -> None:
    import workbook                         # needs openpyxl; tests import us without it

    ap = argparse.ArgumentParser(description="SmartExamSeat dataset generator")
    ap.add_argument("--workbook", default=os.path.join(HERE, "datasets", "big.xlsx"),
                    help="dataset workbook (default: datasets/big.xlsx)")
    ap.add_argument("--stats", action="store_true", help="print a capacity report")
    ap.add_argument("--out", default=HERE, help="output directory")
    args = ap.parse_args()

    sample = build_sample()
    check_and_report(sample, "data_sample.pl (tiny)", args.stats)
    write_prolog(os.path.join(args.out, "data_sample.pl"), sample,
                 "SmartExamSeat tiny sample dataset")

    try:
        full, summary = workbook.generate_from_workbook(args.workbook, args.stats)
    except OSError as exc:
        sys.exit(f"{args.workbook}: {exc}")
    except GenerationError as exc:
        sys.exit(f"{args.workbook}: {exc}")
    write_prolog(os.path.join(args.out, "data.pl"), full,
                 f"SmartExamSeat dataset from {os.path.basename(args.workbook)}")

    if summary:
        print(f"\n{summary}")
    print("wrote data_sample.pl and data.pl")


if __name__ == "__main__":
    main()
