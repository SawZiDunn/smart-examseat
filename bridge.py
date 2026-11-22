#!/usr/bin/env python3
"""
bridge.py - the pyswip bridge between the Prolog engine and Python (Member C).

Loads main.pl (which consults rules.pl, allocation.pl, solver.pl, validator.pl
and the dataset), calls the predicates listed in README.md section 8.4 and turns their
answers into plain Python objects.

Two routes into Prolog are provided:

  * generate_raw()  - calls generate_seating/3 and parses the raw
                      ok(...) / failed(...) term as README.md
                      section 8.6 describes. Used by the tests.
  * generate()      - calls the seating_report_json/3 helper, which returns
                      one JSON atom containing the plan, the validator report
                      and timing stats. Used by the web UI, because shipping
                      ~900 assignments as nested pyswip terms is slow.

The SWI engine is not thread safe, so every query goes through one lock.
"""

from __future__ import annotations

import json
import os
import re
import threading
from dataclasses import dataclass, asdict

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN_PL = os.path.join(HERE, "main.pl")


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Assignment:
    """One result row: assign(Student, Exam, Room, Row, Col)."""
    student: str
    exam: str
    room: str
    row: int
    col: int
    name: str = ""
    major: str = ""
    year: int = 0
    needs_accessible: bool = False

    def as_dict(self) -> dict:
        return asdict(self)


class PrologError(RuntimeError):
    """Raised when a Prolog query fails or the engine cannot be started."""


# ---------------------------------------------------------------------------
# A small Prolog term parser
# ---------------------------------------------------------------------------
# pyswip hands compound terms back as text in the version we use, so instead
# of poking at its internal Functor objects we ask Prolog for the canonical
# text of the term (term_to_atom/2) and parse it here. That is exactly the
# "C parses ok(...) / failed(...)" step from README.md section 8.6.


class Compound:
    """A parsed Prolog compound term: name(args...)."""

    __slots__ = ("name", "args")

    def __init__(self, name, args):
        self.name = name
        self.args = args

    @property
    def arity(self):
        return len(self.args)

    def __repr__(self):
        inner = ", ".join(repr(a) for a in self.args)
        return f"{self.name}({inner})"

    def __eq__(self, other):
        return (isinstance(other, Compound)
                and self.name == other.name and self.args == other.args)


_TOKEN = re.compile(r"""
      \s+                              # whitespace (skipped)
    | (?P<quoted>'(?:\\.|[^'\\])*')   # 'a quoted atom'
    | (?P<number>-?\d+(?:\.\d+)?)     # 123 or -4.5
    | (?P<name>[a-z][A-Za-z0-9_]*)     # bare atom / functor name
    | (?P<var>[A-Z_][A-Za-z0-9_]*)     # a variable
    | (?P<punct>[()\[\],|])            # structure
""", re.VERBOSE)


def _tokenize(text):
    pos, out = 0, []
    while pos < len(text):
        match = _TOKEN.match(text, pos)
        if not match:
            raise PrologError(f"cannot tokenize at {pos}: {text[pos:pos + 30]!r}")
        pos = match.end()
        kind = match.lastgroup
        if kind:
            out.append((kind, match.group()))
    return out


def parse_term(text):
    """Parse canonical Prolog term text into Python values.

    atoms -> str, numbers -> int/float, lists -> list, f(A,B) -> Compound.
    """
    tokens = _tokenize(text)
    value, index = _parse(tokens, 0)
    if index != len(tokens):
        raise PrologError(f"trailing input in term: {text!r}")
    return value


def _parse(tokens, i):
    if i >= len(tokens):
        raise PrologError("unexpected end of term")
    kind, token = tokens[i]

    if kind == "number":
        return (float(token) if "." in token else int(token)), i + 1

    if kind == "var":
        return None, i + 1

    if kind == "punct" and token == "[":
        return _parse_list(tokens, i + 1)

    if kind in ("name", "quoted"):
        name = _unquote(token) if kind == "quoted" else token
        if i + 1 < len(tokens) and tokens[i + 1] == ("punct", "("):
            args, j = _parse_args(tokens, i + 2)
            return Compound(name, args), j
        return name, i + 1

    raise PrologError(f"unexpected token {token!r}")


def _parse_args(tokens, i):
    args = []
    while True:
        value, i = _parse(tokens, i)
        args.append(value)
        if i >= len(tokens):
            raise PrologError("unterminated argument list")
        kind, token = tokens[i]
        if token == ",":
            i += 1
            continue
        if token == ")":
            return args, i + 1
        raise PrologError(f"expected , or ) but found {token!r}")


def _parse_list(tokens, i):
    if i < len(tokens) and tokens[i] == ("punct", "]"):
        return [], i + 1
    items = []
    while True:
        value, i = _parse(tokens, i)
        items.append(value)
        kind, token = tokens[i]
        if token == ",":
            i += 1
            continue
        if token == "]":
            return items, i + 1
        raise PrologError(f"expected , or ] but found {token!r}")


def _unquote(token):
    body = token[1:-1]
    return re.sub(r"\\(.)", r"\1", body)


# ---------------------------------------------------------------------------
# ok(...) / failed(...)
# ---------------------------------------------------------------------------

def parse_result(text):
    """Parse ok([assign(...), ...]) / failed(Reason) into Python.

    Returns (status, payload) where status is "ok" or "failed"; payload is a
    list[Assignment] or a reason dict.
    """
    term = parse_term(text) if isinstance(text, str) else text
    if not isinstance(term, Compound):
        raise PrologError(f"unexpected Result term: {term!r}")

    if term.name == "ok":
        rows = term.args[0] or []
        out = []
        for row in rows:
            if not (isinstance(row, Compound) and row.name == "assign"
                    and row.arity == 5):
                raise PrologError(f"unexpected assignment term: {row!r}")
            student, exam, room, r, c = row.args
            out.append(Assignment(student=str(student), exam=str(exam),
                                  room=str(room), row=int(r), col=int(c)))
        return "ok", out

    if term.name == "failed":
        return "failed", reason_to_dict(term.args[0])

    raise PrologError(f"Result is neither ok/1 nor failed/1: {term.name}")


def reason_to_dict(reason) -> dict:
    """Turn a solver failure reason into something the UI can show."""
    if isinstance(reason, str):
        return {"kind": reason, "message": reason}
    if not isinstance(reason, Compound):
        return {"kind": "other", "message": str(reason)}

    kind, args = reason.name, reason.args
    if kind == "not_enough_seats":
        room, needed, have = args
        return {"kind": kind, "room": str(room),
                "needed": int(needed), "have": int(have),
                "message": (f"Room {room} was given {needed} students "
                            f"but only has {have} seats.")}
    if kind == "not_enough_accessible":
        room, needed, have = args
        return {"kind": kind, "room": str(room),
                "needed": int(needed), "have": int(have),
                "message": (f"Room {room} needs {needed} accessible seats "
                            f"but only has {have}.")}
    if kind == "no_solution":
        room = args[0]
        return {"kind": kind, "room": str(room),
                "message": (f"No seating for room {room} satisfies every "
                            f"constraint, even after reallocation.")}
    if kind == "search_limit":
        room = args[0]
        return {"kind": kind, "room": str(room),
                "message": (f"Seating search for room {room} reached its work "
                            f"limit; the room may still be feasible.")}
    if kind == "search_error":
        room = args[0]
        return {"kind": kind, "room": str(room),
                "message": f"Seating search failed unexpectedly in room {room}."}
    return {"kind": kind, "message": repr(reason)}


def filters_term(years, majors) -> str:
    """Build the Prolog term filters([Years], [Majors])."""
    year_list = "[" + ",".join(str(int(y)) for y in (years or [])) + "]"
    major_list = "[" + ",".join(_atom(m) for m in (majors or [])) + "]"
    return f"filters({year_list},{major_list})"


def _atom(value) -> str:
    text = str(value)
    if text and text[0].islower() and all(c.isalnum() or c == "_" for c in text):
        return text
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"


# ---------------------------------------------------------------------------
# The bridge
# ---------------------------------------------------------------------------

class SeatingEngine:
    """A loaded Prolog knowledge base you can ask for seating plans."""

    def __init__(self, dataset: str | None = None, main_pl: str = MAIN_PL):
        try:
            from pyswip import Prolog
        except ImportError as exc:                       # pragma: no cover
            raise PrologError(
                "pyswip is not installed. Run: pip install pyswip "
                "(and make sure SWI-Prolog itself is installed)."
            ) from exc

        if dataset:
            os.environ["SMARTEXAMSEAT_DATA"] = dataset

        self._lock = threading.Lock()
        self._prolog = Prolog()
        self._prolog.consult(main_pl)
        self.dataset = dataset or "data.pl"

    # -- low level ---------------------------------------------------------

    def _one(self, query: str) -> dict:
        """Run a query that must have exactly one solution."""
        with self._lock:
            answers = list(self._prolog.query(query, maxresult=1))
        if not answers:
            raise PrologError(f"query failed: {query}")
        return answers[0]

    def _all(self, query: str) -> list:
        with self._lock:
            return list(self._prolog.query(query))

    def _json(self, query: str, var: str) -> dict:
        answer = self._one(query)
        raw = answer[var]
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8")
        return json.loads(str(raw))

    # -- catalogue ---------------------------------------------------------

    def catalogue(self) -> dict:
        """Sessions, majors, years, rooms and a dataset summary for the UI."""
        return self._json("catalogue_json(J)", "J")

    def room_layout(self, room_id: str) -> dict:
        """Rows, cols and the seat list (with seat types) of one room."""
        return self._json(f"room_layout_json({_atom(room_id)}, J)", "J")

    def students_in_session(self, session, years=None, majors=None) -> list:
        """[(student_id, exam_code), ...] - A's students_in_session/3."""
        query = (f"students_in_session({_atom(session)}, "
                 f"{filters_term(years, majors)}, L), term_to_atom(L, T)")
        term = parse_term(str(self._one(query)["T"]))
        return [(str(t.args[0]), str(t.args[1])) for t in term]

    def exam_clashes(self, limit: int = 20) -> list:
        """Data sanity check - should always be empty."""
        rows = self._all("exam_clash(S, Sess)")[:limit]
        return [(str(r["S"]), str(r["Sess"])) for r in rows]

    # -- generation --------------------------------------------------------

    def generate_raw(self, session, years=None, majors=None):
        """README section 8.6 route: parse the ok/1 | failed/1 term ourselves.

        Returns ("ok", [Assignment, ...]) or ("failed", reason_dict).
        """
        query = (f"generate_seating({_atom(session)}, "
                 f"{filters_term(years, majors)}, Result), "
                 f"term_to_atom(Result, Text)")
        return parse_result(str(self._one(query)["Text"]))

    def generate(self, session, years=None, majors=None) -> dict:
        """Generate + validate in one Prolog call.

        Returns
            {
              "ok": bool,
              "session": str,
              "filters": {"years": [...], "majors": [...]},
              "assignments": [Assignment, ...],     # [] when ok is False
              "error": {...} | None,
              "validation": {"status": ..., "violations": [...]},
              "stats": {"students":..,"rooms":..,"retries":..,"millis":..},
              "rooms": {room_id: [Assignment, ...]},
            }
        """
        query = (f"seating_report_json({_atom(session)}, "
                 f"{filters_term(years, majors)}, J)")
        payload = self._json(query, "J")

        result = payload["result"]
        ok = result["status"] == "ok"
        assignments = []
        if ok:
            for row in result["assignments"]:
                assignments.append(Assignment(
                    student=row["student"], exam=row["exam"], room=row["room"],
                    row=int(row["row"]), col=int(row["col"]),
                    name=row.get("name", ""), major=row.get("major", ""),
                    year=int(row.get("year", 0) or 0),
                    needs_accessible=row.get("needs_accessible", False)))

        rooms: dict = {}
        for a in assignments:
            rooms.setdefault(a.room, []).append(a)
        for seats in rooms.values():
            seats.sort(key=lambda a: (a.row, a.col))

        error = None
        if not ok:
            error = dict(result.get("detail") or {})
            error.setdefault("message", result.get("reason", "generation failed"))
            if error.get("kind") == "not_enough_seats":
                error["message"] = (
                    f"Room {error['room']} was given {error['needed']} students "
                    f"but only has {error['have']} seats.")
            elif error.get("kind") == "not_enough_accessible":
                error["message"] = (
                    f"Room {error['room']} needs {error['needed']} accessible "
                    f"seats but only has {error['have']}.")
            elif error.get("kind") == "no_solution":
                error["message"] = (
                    f"No seating for room {error['room']} satisfies every "
                    f"constraint, even after reallocation. Try narrowing the "
                    f"filters or making more rooms available.")

        return {
            "ok": ok,
            "session": str(session),
            "filters": {"years": list(years or []), "majors": list(majors or [])},
            "assignments": assignments,
            "rooms": rooms,
            "error": error,
            "validation": payload.get("validation", {}),
            "stats": payload.get("stats", {}),
        }

    # -- capacity and the whole term ---------------------------------------

    def session_cohorts(self, session) -> dict:
        """Who sits this session, per (major, year), plus the seat capacity.

            {"session": .., "seats": N, "accessible_seats": N,
             "cohorts": [{"major", "year", "students", "accessible",
                          "exams": [...]}, ...]}
        """
        return self._json(f"session_cohorts_json({_atom(session)}, J)", "J")

    def term_report(self) -> dict:
        """Seat and validate every session; coverage per (major, year).

            {"sessions": [{"session", "date", "start", "end", "exams",
                           "students", "rooms", "millis", "status",
                           "reason"?, "violations"?}, ...],
             "coverage": [{"major", "year", "seated", "total"}, ...],
             "millis": N}
        """
        return self._json("term_report_json(J)", "J")

    # -- validation --------------------------------------------------------

    def validate(self, session, assignments, years=None, majors=None) -> dict:
        """Run A's validate_seating/4 on a plan we already hold in Python.

        This is the "Validate" button: it proves the displayed plan is legal
        rather than trusting the report that came with it.
        """
        terms = ",".join(
            f"assign({_atom(a.student)},{_atom(a.exam)},{_atom(a.room)},"
            f"{a.row},{a.col})"
            for a in assignments)
        query = (f"validate_seating({_atom(session)}, "
                 f"{filters_term(years, majors)}, [{terms}], Report), "
                 f"( Report == valid "
                 f"-> Out = '{{\"status\":\"valid\",\"violations\":[]}}' "
                 f"; Report = invalid(Vs), "
                 f"  findall(_{{rule: R, message: M}}, "
                 f"    ( member(violation(R,D), Vs), "
                 f"      explain_violation(violation(R,D), M) ), L), "
                 f"  atom_json_dict(Out, _{{status:\"invalid\", violations:L}}, "
                 f"  [as(atom)]) )")
        return self._json(query, "Out")


# ---------------------------------------------------------------------------
# A tiny CLI so the bridge can be exercised without the web UI
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description="SmartExamSeat Prolog bridge")
    ap.add_argument("session", nargs="?", default="sess1")
    ap.add_argument("--years", default="", help="comma separated, e.g. 1,2")
    ap.add_argument("--majors", default="", help="comma separated, e.g. se,cs")
    ap.add_argument("--dataset", default=None, help="data.pl or data_sample.pl")
    ap.add_argument("--room", default=None, help="print this room's grid")
    args = ap.parse_args()

    years = [int(y) for y in args.years.split(",") if y.strip()]
    majors = [m.strip() for m in args.majors.split(",") if m.strip()]

    engine = SeatingEngine(dataset=args.dataset)
    summary = engine.catalogue()["summary"]
    print(f"dataset: {engine.dataset}  "
          f"{summary['students']} students, {summary['subjects']} subjects, "
          f"{summary['rooms_available']} rooms, {summary['seats']} seats")

    report = engine.generate(args.session, years, majors)
    stats = report["stats"]
    if not report["ok"]:
        print(f"FAILED: {report['error']['message']}")
        return

    print(f"ok: {len(report['assignments'])} assignments in "
          f"{len(report['rooms'])} rooms, {stats['retries']} retries, "
          f"{stats['millis']} ms")
    print(f"validation: {report['validation']['status']}")
    for v in report["validation"].get("violations", [])[:10]:
        print(f"  - {v['message']}")

    for room_id in sorted(report["rooms"]):
        print(f"  {room_id}: {len(report['rooms'][room_id])} students")

    if args.room:
        layout = engine.room_layout(args.room)
        taken = {(a.row, a.col): a for a in report["rooms"].get(args.room, [])}
        print(f"\n{args.room} ({layout['rows']}x{layout['cols']})")
        types = {(s["row"], s["col"]): s["type"] for s in layout["seats"]}
        for r in range(1, layout["rows"] + 1):
            cells = []
            for c in range(1, layout["cols"] + 1):
                a = taken.get((r, c))
                if a:
                    cells.append(a.student)
                elif types.get((r, c)) == "accessible":
                    cells.append("[___]")
                else:
                    cells.append(" ... ")
            print(" ".join(cells))


if __name__ == "__main__":
    main()
