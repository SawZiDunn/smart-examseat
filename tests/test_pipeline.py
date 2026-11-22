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
from bridge import (Assignment, Compound, PrologError, SeatingEngine,  # noqa
                    filters_term, parse_result, parse_term)

ENGINE: SeatingEngine | None = None
CONFIG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "config.toml")


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

    def test_summary_matches_the_config(self):
        cohorts = generate_data.cohorts_from(
            generate_data.load_config(CONFIG))
        summary = ENGINE.catalogue()["summary"]
        self.assertEqual(summary["students"],
                         sum(c.students for c in cohorts))
        self.assertEqual(summary["subjects"],
                         sum(c.subjects for c in cohorts if c.students))
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


class TestConfig(unittest.TestCase):

    def test_per_year_accepts_a_number_or_a_list(self):
        self.assertEqual(generate_data.per_year(5, [1, 2], "subjects", "se"),
                         {1: 5, 2: 5})
        self.assertEqual(generate_data.per_year([5, 3], [1, 2], "subjects", "se"),
                         {1: 5, 2: 3})

    def test_per_year_rejects_a_wrong_length_list(self):
        with self.assertRaises(generate_data.ConfigError):
            generate_data.per_year([5, 3, 4], [1, 2], "subjects", "se")

    def test_cohorts_use_major_values_then_defaults(self):
        cfg = {"years": [1, 2], "defaults": {"students": 10, "subjects": 4},
               "majors": {"se": {"subjects": [5, 3]}, "ce": {}}}
        got = {(c.major, c.year): (c.students, c.subjects)
               for c in generate_data.cohorts_from(cfg)}
        self.assertEqual(got, {("se", 1): (10, 5), ("se", 2): (10, 3),
                               ("ce", 1): (10, 4), ("ce", 2): (10, 4)})

    def test_exam_period_skips_weekends(self):
        cfg = {"exam_period": {"start_date": "2026-12-04", "days": 2,
                               "slots": [["09:00", "12:00"]]}}
        dates = [s[1] for s in generate_data.sessions_from(cfg)]
        self.assertEqual(dates, ["2026-12-04", "2026-12-07"])   # Fri, Mon

    def test_subjects_belong_to_one_cohort(self):
        cfg = {"years": [1], "defaults": {"students": 2, "subjects": 2},
               "majors": {"se": {}, "ce": {}},
               "rooms": {"groups": [{"count": 1, "rows": 2, "cols": 2}]}}
        ds = generate_data.build_full(cfg)
        self.assertEqual(sorted(ds.subjects), ["ce101", "ce102", "se101", "se102"])
        major_of = {s[0]: s[1] for s in ds.students}
        for student, code in ds.enrolments:
            self.assertTrue(code.startswith(major_of[student]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
