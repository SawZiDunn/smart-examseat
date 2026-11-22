#!/usr/bin/env python3
"""
tests/test_pipeline.py - Python-side tests for the bridge, UI and exports.

Run from the project root:

    python3 -m unittest discover -s tests -v
    # or
    python3 tests/test_pipeline.py

One Prolog engine is shared by every test (SWI can only be embedded once per
process), so the suite loads the full dataset and switches to the sample via
the Prolog predicate use_sample_data/0 only where that is needed.
"""

from __future__ import annotations

import csv
import io
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import export                                            # noqa: E402
import generate_data                                     # noqa: E402
import workbook                                          # noqa: E402
from bridge import (Assignment, Compound, PrologError, SeatingEngine,  # noqa
                    filters_term, parse_result, parse_term)

ENGINE: SeatingEngine | None = None
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIG = os.path.join(ROOT_DIR, "datasets", "big.xlsx")        # what data.pl is made from
SMALL = os.path.join(ROOT_DIR, "datasets", "small.xlsx")


def setUpModule():
    global ENGINE
    ENGINE = SeatingEngine()


# ---------------------------------------------------------------------------


class TestTermParser(unittest.TestCase):
    """The parser that turns canonical Prolog text into Python values."""

    def test_atom(self):
        self.assertEqual(parse_term("sess1"), "sess1")

    def test_quoted_atom(self):
        self.assertEqual(parse_term("'2026-12-01'"), "2026-12-01")

    def test_integer(self):
        self.assertEqual(parse_term("42"), 42)
        self.assertEqual(parse_term("-7"), -7)

    def test_empty_list(self):
        self.assertEqual(parse_term("[]"), [])

    def test_flat_list(self):
        self.assertEqual(parse_term("[a,b,c]"), ["a", "b", "c"])

    def test_compound(self):
        term = parse_term("assign(s0001,cs101,r101,1,2)")
        self.assertEqual(term.name, "assign")
        self.assertEqual(term.arity, 5)
        self.assertEqual(term.args, ["s0001", "cs101", "r101", 1, 2])

    def test_nested(self):
        term = parse_term("ok([assign(a,b,c,1,2),assign(d,e,f,3,4)])")
        self.assertEqual(term.name, "ok")
        self.assertEqual(len(term.args[0]), 2)
        self.assertEqual(term.args[0][1].args[4], 4)

    def test_whitespace_is_ignored(self):
        self.assertEqual(parse_term("f( a , 1 )"), Compound("f", ["a", 1]))

    def test_rejects_garbage(self):
        with self.assertRaises(PrologError):
            parse_term("f(a,")

    def test_filters_term(self):
        self.assertEqual(filters_term([], []), "filters([],[])")
        self.assertEqual(filters_term([1, 2], ["se", "cs"]),
                         "filters([1,2],[se,cs])")


class TestResultParser(unittest.TestCase):

    def test_ok(self):
        status, rows = parse_result("ok([assign(s0001,cs101,r101,1,2)])")
        self.assertEqual(status, "ok")
        self.assertEqual(rows, [Assignment("s0001", "cs101", "r101", 1, 2)])

    def test_ok_empty(self):
        self.assertEqual(parse_result("ok([])"), ("ok", []))

    def test_failed_not_enough_seats(self):
        status, reason = parse_result("failed(not_enough_seats(r101,50,30))")
        self.assertEqual(status, "failed")
        self.assertEqual(reason["kind"], "not_enough_seats")
        self.assertEqual((reason["needed"], reason["have"]), (50, 30))
        self.assertIn("r101", reason["message"])

    def test_failed_no_solution(self):
        _, reason = parse_result("failed(no_solution(r103))")
        self.assertEqual(reason["kind"], "no_solution")
        self.assertEqual(reason["room"], "r103")

    def test_failed_search_limit_is_not_no_solution(self):
        _, reason = parse_result("failed(search_limit(r103))")
        self.assertEqual(reason["kind"], "search_limit")
        self.assertEqual(reason["room"], "r103")
        self.assertIn("may still be feasible", reason["message"])

    def test_rejects_other_functors(self):
        with self.assertRaises(PrologError):
            parse_result("maybe([])")


# ---------------------------------------------------------------------------


class TestCatalogue(unittest.TestCase):

    def test_summary_matches_the_workbook(self):
        ds, _ = workbook.read_workbook(BIG)
        summary = ENGINE.catalogue()["summary"]
        self.assertEqual(summary["students"], len(ds.students))
        self.assertEqual(summary["subjects"], len(ds.subjects))
        self.assertGreaterEqual(summary["rooms_available"], 10)

    def test_sessions_report_their_headcount(self):
        for s in ENGINE.catalogue()["sessions"]:
            self.assertEqual(s["students"],
                             len(ENGINE.students_in_session(s["id"])))

    def test_sessions_are_in_order(self):
        sessions = [s["id"] for s in ENGINE.catalogue()["sessions"]]
        self.assertEqual(sessions[:3], ["sess1", "sess2", "sess3"])
        self.assertEqual(sessions[-1], f"sess{len(sessions)}")

    def test_every_session_has_a_time(self):
        for s in ENGINE.catalogue()["sessions"]:
            self.assertTrue(s["date"] and s["start"] and s["end"])
            self.assertTrue(s["exams"])

    def test_majors_and_years(self):
        catalogue = ENGINE.catalogue()
        self.assertEqual(catalogue["years"], [1, 2, 3, 4])
        self.assertEqual(len(catalogue["majors"]), 10)

    def test_room_layout(self):
        layout = ENGINE.room_layout("r101")
        self.assertEqual(len(layout["seats"]),
                         layout["rows"] * layout["cols"])
        self.assertTrue(any(s["type"] == "accessible"
                            for s in layout["seats"]))

    def test_dataset_has_no_clashes(self):
        self.assertEqual(ENGINE.exam_clashes(), [])


class TestGeneration(unittest.TestCase):

    def test_generate_is_valid(self):
        report = ENGINE.generate("sess13")
        self.assertTrue(report["ok"])
        self.assertEqual(report["validation"]["status"], "valid")
        self.assertGreater(len(report["assignments"]), 0)

    def test_every_seat_is_unique(self):
        report = ENGINE.generate("sess13")
        seats = [(a.room, a.row, a.col) for a in report["assignments"]]
        self.assertEqual(len(seats), len(set(seats)))

    def test_every_student_appears_once(self):
        report = ENGINE.generate("sess13")
        students = [a.student for a in report["assignments"]]
        self.assertEqual(len(students), len(set(students)))

    def test_matches_students_in_session(self):
        expected = ENGINE.students_in_session("sess13")
        report = ENGINE.generate("sess13")
        got = {(a.student, a.exam) for a in report["assignments"]}
        self.assertEqual(got, set(expected))

    def test_separation_holds(self):
        report = ENGINE.generate("sess13")
        by_row: dict = {}
        for a in report["assignments"]:
            by_row.setdefault((a.room, a.row, a.exam), []).append(a.col)
        for cols in by_row.values():
            cols.sort()
            for first, second in zip(cols, cols[1:]):
                self.assertGreaterEqual(second - first, 2)

    def test_filters_narrow_the_plan(self):
        wide = ENGINE.generate("sess3")
        narrow = ENGINE.generate("sess3", years=[1], majors=["se"])
        self.assertTrue(narrow["ok"])
        self.assertLess(len(narrow["assignments"]), len(wide["assignments"]))
        for a in narrow["assignments"]:
            self.assertEqual(a.year, 1)
            self.assertEqual(a.major, "se")

    def test_no_match_gives_an_empty_plan(self):
        report = ENGINE.generate("sess1", years=[1], majors=["nosuchmajor"])
        self.assertTrue(report["ok"])
        self.assertEqual(report["assignments"], [])

    def test_assignments_carry_names(self):
        report = ENGINE.generate("sess13")
        self.assertTrue(all(a.name for a in report["assignments"]))

    def test_assignments_carry_accessibility_requirement(self):
        report = ENGINE.generate("sess1")
        self.assertTrue(report["ok"])
        self.assertTrue(all(isinstance(a.needs_accessible, bool)
                            for a in report["assignments"]))
        self.assertTrue(any(a.needs_accessible for a in report["assignments"]))
        self.assertTrue(any(not a.needs_accessible
                            for a in report["assignments"]))

    def test_raw_route_agrees_with_json_route(self):
        status, rows = ENGINE.generate_raw("sess13")
        report = ENGINE.generate("sess13")
        self.assertEqual(status, "ok")
        raw = {(a.student, a.exam, a.room, a.row, a.col) for a in rows}
        via_json = {(a.student, a.exam, a.room, a.row, a.col)
                    for a in report["assignments"]}
        self.assertEqual(raw, via_json)

    def test_validate_button_agrees(self):
        report = ENGINE.generate("sess13")
        result = ENGINE.validate("sess13", report["assignments"])
        self.assertEqual(result["status"], "valid")

    def test_validator_catches_a_tampered_plan(self):
        report = ENGINE.generate("sess13")
        rows = list(report["assignments"])
        first = rows[0]
        # give two students the same seat
        rows[1] = Assignment(rows[1].student, rows[1].exam, first.room,
                             first.row, first.col)
        result = ENGINE.validate("sess13", rows)
        self.assertEqual(result["status"], "invalid")
        self.assertTrue(any(v["rule"] == "seat_unique"
                            for v in result["violations"]))

    def test_all_sessions_solve(self):
        for session in [s["id"] for s in ENGINE.catalogue()["sessions"]]:
            with self.subTest(session=session):
                report = ENGINE.generate(session)
                self.assertTrue(report["ok"], report.get("error"))
                self.assertEqual(report["validation"]["status"], "valid")


class TestExports(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.report = ENGINE.generate("sess13")
        cls.layouts = {r: ENGINE.room_layout(r) for r in cls.report["rooms"]}

    def test_csv_has_one_row_per_assignment(self):
        rows = list(csv.DictReader(
            io.StringIO(export.seating_csv(self.report, self.layouts))))
        self.assertEqual(len(rows), len(self.report["assignments"]))
        self.assertEqual(list(rows[0].keys()), export.CSV_COLUMNS)

    def test_csv_seat_types_are_filled_in(self):
        rows = list(csv.DictReader(
            io.StringIO(export.seating_csv(self.report, self.layouts))))
        self.assertTrue(all(r["seat_type"] in ("normal", "accessible")
                            for r in rows))

    def test_room_summary_csv(self):
        rows = list(csv.DictReader(
            io.StringIO(export.room_list_csv(self.report))))
        self.assertEqual(len(rows), len(self.report["rooms"]))
        total = sum(int(r["students"]) for r in rows)
        self.assertEqual(total, len(self.report["assignments"]))

    def test_pdf_is_produced(self):
        pdf = export.seating_pdf(self.report, self.layouts)
        self.assertTrue(pdf.startswith(b"%PDF"))
        self.assertGreater(len(pdf), 5000)

    def test_pdf_for_one_room(self):
        room = sorted(self.report["rooms"])[0]
        pdf = export.seating_pdf(self.report, self.layouts, None, [room])
        self.assertTrue(pdf.startswith(b"%PDF"))


class TestWebApp(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        import app as webapp
        webapp.ENGINE = ENGINE
        cls.webapp = webapp
        cls.client = webapp.app.test_client()

    def test_index_renders(self):
        res = self.client.get("/")
        self.assertEqual(res.status_code, 200)
        self.assertIn(b"SmartExamSeat", res.data)
        self.assertIn(b"sess1", res.data)

    def test_generate_endpoint(self):
        res = self.client.post("/api/generate", json={"session": "sess13"})
        self.assertEqual(res.status_code, 200)
        data = res.get_json()
        self.assertTrue(data["ok"])
        self.assertEqual(data["validation"]["status"], "valid")
        self.assertEqual(sum(r["count"] for r in data["rooms"]), data["total"])

    def test_generate_needs_a_session(self):
        res = self.client.post("/api/generate", json={})
        self.assertEqual(res.status_code, 400)

    def test_rooms_carry_their_layout(self):
        data = self.client.post("/api/generate",
                                json={"session": "sess13"}).get_json()
        room = data["rooms"][0]
        self.assertTrue(room["rows"] and room["cols"])
        self.assertTrue(room["seatTypes"])
        for a in room["assignments"]:
            self.assertLessEqual(a["row"], room["rows"])
            self.assertLessEqual(a["col"], room["cols"])

    def test_validate_endpoint(self):
        self.client.post("/api/generate", json={"session": "sess13"})
        res = self.client.post("/api/validate", json={"session": "sess13"})
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.get_json()["status"], "valid")

    def test_validate_without_a_plan(self):
        res = self.client.post("/api/validate", json={"session": "sess11",
                                                      "years": [3],
                                                      "majors": ["bme"]})
        self.assertEqual(res.status_code, 400)

    def test_csv_download(self):
        res = self.client.get("/export/csv?session=sess13")
        self.assertEqual(res.status_code, 200)
        self.assertIn("attachment", res.headers["Content-Disposition"])
        self.assertIn("sess13", res.headers["Content-Disposition"])

    def test_pdf_download(self):
        res = self.client.get("/export/pdf?session=sess13")
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.data.startswith(b"%PDF"))

    def test_filtered_download_name(self):
        res = self.client.get("/export/csv?session=sess3&years=1&majors=se")
        self.assertEqual(res.status_code, 200)
        self.assertIn("sess3_y1_se", res.headers["Content-Disposition"])

    def test_room_layout_endpoint(self):
        res = self.client.get("/api/room/r101")
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.get_json()["room"], "r101")

    def test_data_page_renders_and_is_linked(self):
        res = self.client.get("/data")
        self.assertEqual(res.status_code, 200)
        self.assertIn(b"Timetable", res.data)
        self.assertIn(b'href="/data"', self.client.get("/").data)

    def test_dataset_endpoint_matches_the_catalogue(self):
        data = self.client.get("/api/dataset").get_json()
        summary = ENGINE.catalogue()["summary"]
        self.assertEqual(len(data["students"]), summary["students"])
        self.assertEqual(len(data["subjects"]), summary["subjects"])
        self.assertEqual(data["seats"], summary["seats"])
        # every subject is timetabled, and its headcount is its enrolments
        self.assertTrue(all(s["session"] for s in data["subjects"]))
        enrolments = sum(len(s["exams"]) for s in data["students"])
        self.assertEqual(sum(s["students"] for s in data["subjects"]), enrolments)

    def test_dataset_subjects_name_their_cohorts(self):
        data = self.client.get("/api/dataset").get_json()
        se101 = next(s for s in data["subjects"] if s["code"] == "se101")
        self.assertEqual(se101["cohorts"], [{"major": "se", "year": 1}])


class TestConfigImport(unittest.TestCase):
    """Importing a config in the UI: generate, timetable, load - no make data.

    The engine is shared with the other tests, so every test puts data.pl
    back when it is done.
    """

    @classmethod
    def setUpClass(cls):
        import tempfile
        import app as webapp
        webapp.ENGINE = ENGINE
        cls.webapp = webapp
        cls.client = webapp.app.test_client()
        cls.tmp = tempfile.TemporaryDirectory()
        cls.saved_out = webapp.OUT_DIR
        webapp.OUT_DIR = cls.tmp.name

    @classmethod
    def tearDownClass(cls):
        cls.webapp.OUT_DIR = cls.saved_out
        cls.tmp.cleanup()

    def tearDown(self):
        ENGINE.load_dataset(os.path.join(ROOT_DIR, "data.pl"),
                            label="data.pl")
        self.webapp._CACHE.clear()
        self.webapp._LAYOUTS.clear()

    def test_without_data_pages_go_to_import_and_apis_refuse(self):
        ENGINE.dataset = None
        res = self.client.get("/")
        self.assertEqual(res.status_code, 302)
        self.assertTrue(res.headers["Location"].endswith("/import"))
        self.assertEqual(self.client.get("/data").status_code, 302)
        self.assertEqual(self.client.get("/api/catalogue").status_code, 409)
        self.assertEqual(self.client.get("/import").status_code, 200)

    def upload(self, name, data: bytes):
        return self.client.post("/api/import",
                                data={"workbook": (io.BytesIO(data), name)},
                                content_type="multipart/form-data")

    def small_workbook(self, change=None) -> bytes:
        """datasets/small.xlsx, optionally edited by change(openpyxl workbook)."""
        with open(SMALL, "rb") as fh:
            data = fh.read()
        if change is None:
            return data
        from openpyxl import load_workbook
        wb = load_workbook(io.BytesIO(data))
        change(wb)
        out = io.BytesIO()
        wb.save(out)
        return out.getvalue()

    def test_import_page_has_the_upload_box(self):
        res = self.client.get("/import")
        self.assertEqual(res.status_code, 200)
        self.assertIn(b'type="file"', res.data)

    def test_example_workbooks_can_be_downloaded(self):
        res = self.client.get("/import/example/small.xlsx")
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.data.startswith(b"PK"))          # a zip, i.e. .xlsx
        res.close()
        self.assertEqual(self.client.get("/import/example/other.xlsx").status_code, 404)

    def test_uploading_a_workbook_loads_it(self):
        res = self.upload("small.xlsx", self.small_workbook())
        data = res.get_json()
        self.assertTrue(data["ok"], data)
        self.assertEqual(data["summary"]["students"], 120)
        self.assertEqual(data["summary"]["sessions"], 6)
        self.assertEqual(ENGINE.dataset, "small.xlsx")
        self.assertTrue(os.path.exists(os.path.join(self.tmp.name, "data_small.pl")))
        plan = self.client.post("/api/generate", json={"session": "sess1"}).get_json()
        self.assertTrue(plan["ok"])
        self.assertEqual(plan["validation"]["status"], "valid")

    def test_a_workbook_that_cannot_be_timetabled_is_refused_readably(self):
        def one_day(wb):
            wb["Exam period"]["B3"] = 1
        res = self.upload("tight.xlsx", self.small_workbook(one_day))
        self.assertEqual(res.status_code, 400)
        self.assertIn("at least 3 sessions", res.get_json()["message"])
        self.assertEqual(ENGINE.dataset, "data.pl")      # old data kept

    def test_mistakes_in_the_sheets_are_named_with_their_row(self):
        def break_it(wb):
            wb["Students"]["D2"] = "two"                 # year
            wb["Students"]["E3"] = "crutches"            # access
            wb["Subjects"].append(["ee105", "EE", 1])    # no EE year-1 students
            wb["Rooms"]["E2"] = "maybe"
        res = self.upload("broken.xlsx", self.small_workbook(break_it))
        self.assertEqual(res.status_code, 400)
        msg = res.get_json()["message"]
        self.assertIn("Students row 2: Year must be a whole number", msg)
        self.assertIn("Students row 3: Access must be none, wheelchair", msg)
        self.assertIn("ee105 is for EE year 1, but no student", msg)
        self.assertIn("Rooms row 2: Available must be yes or no", msg)
        self.assertEqual(ENGINE.dataset, "data.pl")

    def test_bad_input_is_refused(self):
        self.assertEqual(self.upload("bad.xlsx", b"not a zip").status_code, 400)
        self.assertEqual(self.upload("old.toml", b"x = 1").status_code, 400)
        self.assertEqual(self.client.post("/api/import").status_code, 400)


class TestConstraintsApi(unittest.TestCase):
    """The Constraints page: list, add, change, remove, run, blame.

    Runs on the 20-student sample so evaluate is fast; data.pl and the
    default constraints are put back after every test.
    """

    ROOT = ROOT_DIR

    @classmethod
    def setUpClass(cls):
        import app as webapp
        webapp.ENGINE = ENGINE
        cls.webapp = webapp
        cls.client = webapp.app.test_client()

    def setUp(self):
        ENGINE.load_dataset(os.path.join(self.ROOT, "data_sample.pl"), label="sample")
        ENGINE.reset_constraints()

    def tearDown(self):
        ENGINE.reset_constraints()
        ENGINE.load_dataset(os.path.join(self.ROOT, "data.pl"), label="data.pl")
        self.webapp._CACHE.clear()
        self.webapp._LAYOUTS.clear()

    def add(self, **body):
        return self.client.post("/api/constraints", json=body)

    def active_terms(self):
        return [a["term"] for a in self.client.get("/api/constraints").get_json()["active"]]

    def test_page_and_listing(self):
        self.assertEqual(self.client.get("/constraints").status_code, 200)
        data = self.client.get("/api/constraints").get_json()
        self.assertEqual([a["term"] for a in data["active"]],
                         ["separation(1)", "accessible_seats", "session_fill(80)",
                          "max_exams_per_day(1)"])
        self.assertEqual(len(data["core"]), 6)
        self.assertIn("column_gap", {c["name"] for c in data["catalog"]})
        self.assertTrue(any(v["head"].startswith("next_to") for v in data["vocabulary"]))

    def test_add_change_and_remove(self):
        res = self.add(term="column_gap(1)", strength="soft", weight=4)
        self.assertTrue(res.get_json()["ok"])
        cid = res.get_json()["id"]
        self.assertIn("column_gap(1)", self.active_terms())
        self.assertEqual(self.client.patch(f"/api/constraints/{cid}",
                                           json={"strength": "hard"}).status_code, 200)
        row = next(a for a in self.client.get("/api/constraints").get_json()["active"]
                   if a["id"] == cid)
        self.assertEqual(row["strength"], "hard")
        self.client.delete(f"/api/constraints/{cid}")
        self.assertNotIn("column_gap(1)", self.active_terms())

    def test_bad_constraints_come_back_as_messages(self):
        for term in ("separation(x)", "foo(1)", "separation(", "separation(N)"):
            res = self.add(term=term)
            self.assertEqual(res.status_code, 400, term)
            self.assertFalse(res.get_json()["ok"])
            self.assertTrue(res.get_json()["message"])
        self.assertEqual(self.add(term="room_fill(80)", strength="soft").status_code, 400)

    def test_custom_rule_with_quotes_and_newlines(self):
        rule = ("% neighbours from different years\n"
                "violation(S1-S2) :-\n    next_to(S1, S2),\n"
                "    year(S1, Y1), year(S2, Y2), Y1 =\\= Y2.")
        res = self.add(custom={"level": "seat", "name": "it's mine", "rule": rule},
                       strength="soft", weight=1)
        self.assertTrue(res.get_json()["ok"], res.get_json())
        unsafe = self.add(custom={"level": "seat", "name": "x",
                                  "rule": "violation(X) :- shell('rm -rf /'), X = 1."})
        self.assertEqual(unsafe.status_code, 400)
        self.assertIn("not allowed", unsafe.get_json()["message"])

    def test_run_reports_feasibility_score_and_rooms(self):
        self.add(custom={"level": "seat", "name": "front row",
                         "rule": "violation(S) :- seated(S, _, _, 1, _)."},
                 strength="soft", weight=2)
        report = self.client.post("/api/evaluate").get_json()
        self.assertTrue(report["feasible"])
        self.assertEqual(report["problems"], [])
        soft = next(s for s in report["soft"] if "front row" in s["term"])
        self.assertGreater(soft["count"], 0)
        self.assertEqual(soft["penalty"], 2 * soft["count"])
        self.assertGreaterEqual(report["rooms"]["peak"], 1)
        self.assertTrue(all(s["ok"] for s in report["sessions"]))

    def test_infeasible_run_and_blame(self):
        self.add(term="room_fill(30)")
        report = self.client.post("/api/evaluate").get_json()
        self.assertFalse(report["feasible"])
        self.assertTrue(report["problems"])
        why = self.client.post("/api/why").get_json()["relaxations"]
        fixes = [r["term"] for r in why if r["feasible"]]
        self.assertEqual(fixes, ["room_fill(30)"])

    def test_reset(self):
        self.add(term="no_diagonal")
        self.client.post("/api/constraints/reset")
        self.assertNotIn("no_diagonal", self.active_terms())


class TestPlannerApi(unittest.TestCase):
    """The Planner page: try days x slots x room pool, score, apply."""

    ROOT = ROOT_DIR
    ONE_SLOT = [["09:00", "12:00"]]

    @classmethod
    def setUpClass(cls):
        import app as webapp
        webapp.ENGINE = ENGINE
        cls.webapp = webapp
        cls.client = webapp.app.test_client()

    def setUp(self):
        ENGINE.load_dataset(os.path.join(self.ROOT, "data_sample.pl"), label="sample")
        ENGINE.reset_constraints()

    def tearDown(self):
        ENGINE.reset_constraints()
        ENGINE.load_dataset(os.path.join(self.ROOT, "data.pl"), label="data.pl")
        self.webapp._CACHE.clear()
        self.webapp._LAYOUTS.clear()

    def option(self, **over):
        body = {"days": 1, "slots": self.ONE_SLOT, "start": "2026-12-01",
                "pool": [{"rows": 4, "cols": 5, "count": 1}, {"rows": 3, "cols": 5, "count": 1}],
                "weights": {"day": 100, "room": 50}}
        body.update(over)
        return self.client.post("/api/plan/option", json=body)

    def test_page_and_setup(self):
        self.assertEqual(self.client.get("/planner").status_code, 200)
        setup = self.client.get("/api/plan/setup").get_json()
        self.assertEqual(setup["start"], "2026-12-01")
        self.assertEqual(setup["days"], 1)
        self.assertEqual(setup["students"], 20)
        self.assertEqual({(p["rows"], p["cols"]) for p in setup["pool"]}, {(4, 5), (3, 5)})

    def test_a_feasible_option_has_a_score(self):
        r = self.option().get_json()
        self.assertTrue(r["feasible"])
        self.assertEqual(r["score"], r["day_cost"] + r["room_cost"] + r["penalty"])
        self.assertEqual(r["day_cost"], 100)
        self.assertGreaterEqual(r["rooms_needed"], 1)
        # the loaded setup is untouched
        self.assertEqual(ENGINE.catalogue()["summary"]["sessions"], 1)

    def test_an_infeasible_option_says_why(self):
        r = self.option(pool=[{"rows": 2, "cols": 2, "count": 1}]).get_json()
        self.assertFalse(r["feasible"])
        self.assertIsNone(r["score"])
        self.assertTrue(r["why"])

    def test_bad_input_is_refused(self):
        self.assertEqual(self.option(days=0).status_code, 400)
        self.assertEqual(self.option(slots=[["9am", "noon"]]).status_code, 400)
        self.assertEqual(self.option(start="tomorrow").status_code, 400)
        self.assertEqual(self.option(pool=[]).status_code, 400)
        self.assertEqual(self.option(weights={"day": -1, "room": 0}).status_code, 400)

    def test_apply_makes_it_the_loaded_setup(self):
        res = self.client.post("/api/plan/apply", json={
            "days": 2, "slots": [["09:00", "12:00"], ["13:00", "16:00"]],
            "start": "2026-12-01", "pool": [{"rows": 5, "cols": 5, "count": 2}]})
        self.assertTrue(res.get_json()["ok"])
        summary = ENGINE.catalogue()["summary"]
        self.assertEqual(summary["sessions"], 4)
        self.assertEqual(summary["rooms_available"], 2)


class TestCapacityAndTerm(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        import app as webapp
        webapp.ENGINE = ENGINE
        cls.webapp = webapp
        cls.client = webapp.app.test_client()

    def test_cohorts_endpoint_adds_up(self):
        data = self.client.get("/api/session/sess1/cohorts").get_json()
        self.assertGreater(data["seats"], 0)
        self.assertEqual(sum(c["students"] for c in data["cohorts"]),
                         len(ENGINE.students_in_session("sess1")))
        for c in data["cohorts"]:
            self.assertTrue(c["exams"])

    def test_selection_count_follows_filters(self):
        cohorts = ENGINE.session_cohorts("sess1")
        everyone, _ = self.webapp.selection_count(cohorts, [], [])
        year1, _ = self.webapp.selection_count(cohorts, [1], [])
        self.assertEqual(
            year1, len(ENGINE.students_in_session("sess1", years=[1])))
        self.assertLessEqual(year1, everyone)

    def test_over_capacity_is_refused_before_solving(self):
        real = ENGINE.session_cohorts
        try:
            ENGINE.session_cohorts = lambda s: {**real(s), "seats": 10}
            res = self.client.post("/api/generate", json={"session": "sess1"})
            self.assertEqual(res.status_code, 400)
            self.assertEqual(res.get_json()["error"]["kind"], "over_capacity")
            res = self.client.get("/export/csv?session=sess1")
            self.assertEqual(res.status_code, 400)
        finally:
            ENGINE.session_cohorts = real

    def test_within_capacity_is_allowed(self):
        res = self.client.post("/api/generate",
                               json={"session": "sess1", "years": [1]})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.get_json()["ok"])

    def test_whole_term_finishes_every_cohort(self):
        data = self.client.post("/api/term").get_json()
        self.assertEqual(len(data["sessions"]),
                         len(ENGINE.catalogue()["sessions"]))
        self.assertTrue(all(s["status"] == "ok" for s in data["sessions"]))
        for c in data["coverage"]:
            self.assertEqual(c["seated"], c["total"], c)


class TestWorkbook(unittest.TestCase):
    """The .xlsx format: what the admin types in, and the round trip."""

    def test_big_workbook_matches_data_pl(self):
        ds, fill = workbook.read_workbook(BIG)
        self.assertEqual(fill, 80)
        self.assertEqual(len(ds.students), 1925)
        self.assertEqual(len(ds.subjects), 191)
        self.assertEqual(len(ds.enrolments), 9180)
        self.assertEqual(len(ds.sessions), 20)

    def test_real_style_ids_and_uppercase_majors_are_accepted(self):
        from openpyxl import load_workbook
        wb = load_workbook(SMALL)
        wb["Students"]["A2"] = 67011653                  # typed as a number
        wb["Subjects"]["A2"] = "SE-101"
        out = io.BytesIO()
        wb.save(out)
        ds, _ = workbook.read_workbook(out.getvalue())
        self.assertEqual(ds.students[0][:3], ("67011653", "se", 1))
        self.assertIn(("67011653", "se-101"), ds.enrolments)

    def test_mornings_only_when_the_afternoon_is_left_empty(self):
        from openpyxl import load_workbook
        wb = load_workbook(SMALL)
        wb["Exam period"]["B6"] = None
        wb["Exam period"]["B7"] = None
        out = io.BytesIO()
        wb.save(out)
        ds, _ = workbook.read_workbook(out.getvalue())
        self.assertEqual({(s[2], s[3]) for s in ds.sessions}, {("09:30", "12:30")})
        self.assertEqual(len(ds.sessions), 3)

    def test_summary_sheet_uses_formulas(self):
        from openpyxl import load_workbook
        ws = load_workbook(SMALL)["Summary"]
        self.assertEqual(ws["A5"].value, "SE")
        self.assertTrue(str(ws["C5"].value).startswith("=COUNTIFS(Students!"))


class TestSessions(unittest.TestCase):

    def test_exam_period_skips_weekends(self):
        sessions = generate_data.sessions_from("2026-12-04", 2, [["09:30", "12:30"]])
        self.assertEqual([s[1] for s in sessions], ["2026-12-04", "2026-12-07"])  # Fri, Mon


if __name__ == "__main__":
    unittest.main(verbosity=2)
