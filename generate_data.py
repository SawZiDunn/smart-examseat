#!/usr/bin/env python3
"""
SmartExamSeat - dataset generator (Member A).

Reads config.toml and writes Prolog fact files that follow the schema in
README.md section 8.2:

    student(Id, Major, Year, Access).
    student_name(Id, Name).
    subject(Code).
    enrolled(Id, Code).
    exam(Code, Session).
    session_time(Session, Date, Start, End).
    room(RoomId, Rows, Cols, Available).
    seat(RoomId, Row, Col, SeatType).

How the full dataset is built:

    1. every (major, year) cohort gets its own students and its OWN subjects
       (counts from config.toml; subjects are never shared between cohorts),
       and every student of a cohort is enrolled in all of its subjects;
    2. rooms and the exam period's sessions come from config.toml;
    3. the exam timetable (exam/2: which session each subject is in) is found
       by the Prolog timetabling CSP in timetable.pl, which guarantees no
       student has two exams in one session and no session overflows.

Two datasets are produced:

    data_sample.pl   tiny smoke-test set  (20 students, 2 rooms, 1 session)
    data.pl          full dataset described by config.toml

Usage:
    python3 generate_data.py                  # write both files
    python3 generate_data.py --stats          # also print a capacity report
    python3 generate_data.py --config my.toml --out somewhere/
"""

from __future__ import annotations

import argparse
import datetime
import os
import random
import re
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN_PL = os.path.join(HERE, "main.pl")

FIRST_NAMES = [
    "Aung", "Mya", "Thandar", "Kyaw", "Nilar", "Zaw", "Hnin", "Soe", "Ei",
    "Min", "Thiri", "Htet", "Yadanar", "Phyo", "Chan", "Nay", "Su", "Wai",
    "Kaung", "May", "Zin", "Tun", "Khin", "Myat", "Pyae", "Shwe", "Nanda",
    "Lwin", "Moe", "Yee",
]
LAST_NAMES = [
    "Hlaing", "Oo", "Win", "Htun", "Aye", "Naing", "Lin", "Maung", "Kyi",
    "Thu", "Swe", "Mon", "Nyein", "Sann", "Htay", "Phyu", "Zaw", "Myint",
    "Tin", "Latt",
]

ACCESS_KINDS = ["wheelchair", "other_accessible"]


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


@dataclass
class Cohort:
    major: str
    year: int
    students: int
    subjects: int


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

class ConfigError(Exception):
    pass


def load_config(path: str) -> dict:
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def per_year(value, years: list, what: str, major: str) -> dict:
    """A number for every year, or a list with one number per year."""
    if isinstance(value, int):
        return {y: value for y in years}
    if isinstance(value, list) and len(value) == len(years) \
            and all(isinstance(v, int) for v in value):
        return dict(zip(years, value))
    raise ConfigError(
        f"majors.{major}.{what} must be a number or a list of {len(years)} "
        f"numbers (one per year), got {value!r}")


def cohorts_from(cfg: dict) -> list:
    years = cfg.get("years", [1, 2, 3, 4])
    defaults = cfg.get("defaults", {})
    majors = cfg.get("majors", {})
    if not majors:
        raise ConfigError("config has no [majors.<code>] tables")
    out = []
    for major, spec in majors.items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*", major):
            raise ConfigError(f"major code {major!r} must be lowercase letters/digits")
        students = per_year(spec.get("students", defaults.get("students", 50)),
                            years, "students", major)
        subjects = per_year(spec.get("subjects", defaults.get("subjects", 5)),
                            years, "subjects", major)
        for y in years:
            if students[y] < 0 or subjects[y] < 0:
                raise ConfigError(f"majors.{major}: counts cannot be negative")
            out.append(Cohort(major, y, students[y], subjects[y]))
    return out


def sessions_from(cfg: dict) -> list:
    """One session per slot per weekday of the exam period."""
    period = cfg.get("exam_period", {})
    day = datetime.date.fromisoformat(period.get("start_date", "2026-12-01"))
    days = period.get("days", 8)
    slots = period.get("slots", [["09:00", "12:00"], ["13:00", "16:00"]])
    out, used = [], 0
    while used < days:
        if day.weekday() < 5:                       # Mon-Fri
            used += 1
            for start, end in slots:
                out.append((f"sess{len(out) + 1}", day.isoformat(), start, end))
        day += datetime.timedelta(days=1)
    return out


def rooms_from(cfg: dict) -> tuple:
    spec = cfg.get("rooms", {})
    acc_cols = spec.get("accessible_front_cols", [1, 3, 5, 7])
    rooms, seats = [], []
    n = 100
    for group in spec.get("groups", []):
        for _ in range(group["count"]):
            n += 1
            room_id = f"r{n}"
            rows, cols = group["rows"], group["cols"]
            rooms.append((room_id, rows, cols,
                          "yes" if group.get("available", True) else "no"))
            for row in range(1, rows + 1):
                for col in range(1, cols + 1):
                    kind = "accessible" if row == 1 and col in acc_cols else "normal"
                    seats.append((room_id, row, col, kind))
    if not rooms:
        raise ConfigError("config has no [[rooms.groups]]")
    return rooms, seats


# --------------------------------------------------------------------------
# building
# --------------------------------------------------------------------------

def subject_code(major: str, year: int, k: int) -> str:
    """se + year 1 + subject 03 -> se103 (README section 8.1)."""
    return f"{major}{year}{k:02d}"


def build_full(cfg: dict) -> Dataset:
    """Everything except the timetable (exam/2), which Prolog decides."""
    rng = random.Random(cfg.get("seed", 20261115))
    access_rate = cfg.get("defaults", {}).get("access_rate", 0.03)

    ds = Dataset()
    ds.sessions = sessions_from(cfg)
    ds.rooms, ds.seats = rooms_from(cfg)

    sid = 0
    for cohort in cohorts_from(cfg):
        codes = [subject_code(cohort.major, cohort.year, k)
                 for k in range(1, cohort.subjects + 1)]
        if cohort.students:
            ds.subjects.extend(codes)
        for _ in range(cohort.students):
            sid += 1
            student_id = f"s{sid:04d}"
            access = (rng.choice(ACCESS_KINDS)
                      if rng.random() < access_rate else "none")
            ds.students.append((student_id, cohort.major, cohort.year, access))
            ds.names.append((student_id,
                             f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)}"))
            for code in codes:
                ds.enrolments.append((student_id, code))
    return ds


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
            sys.exit("swipl not found - install SWI-Prolog (see requirements.txt)")

    exams, summary = [], ""
    for line in proc.stdout.splitlines():
        m = re.fullmatch(r"exam\((\w+), (\w+)\)\.", line.strip())
        if m:
            exams.append((m.group(1), m.group(2)))
        elif line.startswith("% timetable:"):
            summary = line[2:]
        elif line.startswith("FAILED:"):
            sys.exit(f"timetabling failed: {line[len('FAILED:'):].strip()}")
    if proc.returncode != 0 or not exams and ds.subjects:
        sys.exit(f"timetabling failed (exit {proc.returncode}):\n"
                 f"{proc.stdout}\n{proc.stderr}")
    return exams, summary


def build_sample() -> Dataset:
    """Tiny hand-sized dataset: 20 students, 2 subjects, 1 session, 2 rooms."""
    ds = Dataset()
    ds.sessions = [("sess1", "2026-12-01", "09:00", "12:00")]
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
        "% GENERATED FILE - produced by generate_data.py from config.toml,",
        "% do not edit by hand. Schema: README.md section 8.2.",
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
    ap = argparse.ArgumentParser(description="SmartExamSeat dataset generator")
    ap.add_argument("--config", default=os.path.join(HERE, "config.toml"),
                    help="dataset configuration (default: config.toml)")
    ap.add_argument("--stats", action="store_true", help="print a capacity report")
    ap.add_argument("--out", default=HERE, help="output directory")
    args = ap.parse_args()

    sample = build_sample()
    check_and_report(sample, "data_sample.pl (tiny)", args.stats)
    write_prolog(os.path.join(args.out, "data_sample.pl"), sample,
                 "SmartExamSeat tiny sample dataset")

    try:
        cfg = load_config(args.config)
        full = build_full(cfg)
    except (ConfigError, KeyError, ValueError, tomllib.TOMLDecodeError) as exc:
        sys.exit(f"{args.config}: {exc}")

    fill = cfg.get("timetable", {}).get("max_fill_percent", 80)
    full.exams, summary = run_timetabler(full, fill)
    check_and_report(full, "data.pl (full)", args.stats)
    write_prolog(os.path.join(args.out, "data.pl"), full,
                 "SmartExamSeat full dataset")

    if summary:
        print(f"\n{summary}")
    print("wrote data_sample.pl and data.pl")


if __name__ == "__main__":
    main()
