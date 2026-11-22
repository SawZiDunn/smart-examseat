#!/usr/bin/env python3
"""
app.py - the admin web UI for SmartExamSeat (Member C).

    python3 app.py                      # http://127.0.0.1:5000, starts empty
    python3 app.py --dataset data.pl    # start with a generated data file
    python3 app.py --port 8080

Without --dataset the app starts with no data: the admin first uploads a
config (e.g. config_small.toml or config_big.toml) on /import, and the app
generates and timetables it - what `make data` does - and loads
the result. Generated files go to out/ and never replace data.pl.

The admin picks a session plus optional year/major filters, presses Generate,
and gets the seat grid for each room, a student list, the validator report,
and CSV / PDF downloads.

All Prolog work happens in bridge.py; this file only serves HTTP.
"""

from __future__ import annotations

import argparse
import os
import re
import threading
import time
import tomllib

from flask import (Flask, jsonify, redirect, render_template, request,
                   Response, send_file, url_for)

import export
import generate_data
from bridge import SeatingEngine, PrologError

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "out")

app = Flask(__name__)

ENGINE: SeatingEngine | None = None
_LOCK = threading.Lock()
_CACHE: dict = {}            # key -> report, so exports reuse the shown plan
_LAYOUTS: dict = {}          # room_id -> layout, fetched once


def engine() -> SeatingEngine:
    if ENGINE is None:                                   # pragma: no cover
        raise RuntimeError("engine not started")
    return ENGINE


def has_data() -> bool:
    return ENGINE is not None and ENGINE.dataset is not None


# Pages and endpoints that work before any data is loaded.
_OPEN_PATHS = ("/import", "/api/import", "/static/")


@app.before_request
def require_data():
    """Before a config is imported there is nothing to show: pages go to
    /import, API and export calls get a 409."""
    if has_data() or request.path.startswith(_OPEN_PATHS):
        return None
    if request.path.startswith(("/api/", "/export/")):
        return jsonify({"error": "no_dataset",
                        "message": "Import a config first."}), 409
    return redirect(url_for("import_page"))


def layout_of(room_id: str) -> dict:
    if room_id not in _LAYOUTS:
        _LAYOUTS[room_id] = engine().room_layout(room_id)
    return _LAYOUTS[room_id]


def read_filters(source) -> tuple:
    """Pull (session, years, majors) out of a JSON body or a query string."""
    session = (source.get("session") or "").strip()
    years = source.get("years") or []
    majors = source.get("majors") or []
    if isinstance(years, str):
        years = [y for y in years.split(",") if y.strip()]
    if isinstance(majors, str):
        majors = [m for m in majors.split(",") if m.strip()]
    years = [int(y) for y in years]
    majors = [str(m) for m in majors]
    return session, years, majors


def cache_key(session, years, majors) -> tuple:
    return (session, tuple(sorted(years)), tuple(sorted(majors)))


def selection_count(cohorts: dict, years, majors) -> tuple:
    """(students, accessible) picked by a year/major filter. Empty = all."""
    n = na = 0
    for c in cohorts["cohorts"]:
        if (not years or c["year"] in years) and \
                (not majors or c["major"] in majors):
            n += c["students"]
            na += c["accessible"]
    return n, na


def capacity_error(session, years, majors) -> dict | None:
    """Refuse a selection bigger than the open rooms, before any solving.

    Whether a seat plan exists inside that capacity is the solver's job;
    this only stops a request that can never fit.
    """
    with _LOCK:
        cohorts = engine().session_cohorts(session)
    n, na = selection_count(cohorts, years, majors)
    if n > cohorts["seats"]:
        return {"kind": "over_capacity", "selected": n,
                "seats": cohorts["seats"],
                "message": (f"{n} students selected but the open rooms only "
                            f"have {cohorts['seats']} seats. Untick some "
                            f"years or majors.")}
    if na > cohorts["accessible_seats"]:
        return {"kind": "over_accessible_capacity", "selected": na,
                "seats": cohorts["accessible_seats"],
                "message": (f"{na} selected students need an accessible seat "
                            f"but there are only "
                            f"{cohorts['accessible_seats']}. Untick some "
                            f"years or majors.")}
    return None


def get_report(session, years, majors, refresh=False) -> dict:
    """Generate (or reuse) a plan. Serialised: one Prolog engine, one caller."""
    key = cache_key(session, years, majors)
    with _LOCK:
        if refresh or key not in _CACHE:
            _CACHE[key] = engine().generate(session, years, majors)
        return _CACHE[key]


def report_to_json(report: dict) -> dict:
    """Shape a report for the browser - rooms carry their seat layout."""
    rooms = []
    for room_id in sorted(report["rooms"]):
        seats = report["rooms"][room_id]
        layout = layout_of(room_id)
        rooms.append({
            "id": room_id,
            "rows": layout["rows"],
            "cols": layout["cols"],
            "count": len(seats),
            "exams": sorted({a.exam for a in seats}),
            "seatTypes": [[s["row"], s["col"]] for s in layout["seats"]
                          if s["type"] == "accessible"],
            "assignments": [a.as_dict() for a in seats],
        })
    return {
        "ok": report["ok"],
        "session": report["session"],
        "filters": report["filters"],
        "error": report["error"],
        "validation": report["validation"],
        "stats": report["stats"],
        "total": len(report["assignments"]),
        "rooms": rooms,
    }


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    catalogue = engine().catalogue()
    return render_template("index.html", catalogue=catalogue,
                           dataset=engine().dataset)


# ---------------------------------------------------------------------------
# Importing a config: generate + timetable + load, without `make data`
# ---------------------------------------------------------------------------

def import_config(cfg: dict, name: str) -> dict:
    """Generate and timetable a config, write it to out/, load it."""
    started = time.time()
    ds, timetable = generate_data.generate(cfg)
    os.makedirs(OUT_DIR, exist_ok=True)
    stem = re.sub(r"[^A-Za-z0-9_-]+", "_", os.path.splitext(name)[0]) or "config"
    path = os.path.join(OUT_DIR, f"data_{stem}.pl")
    generate_data.write_prolog(path, ds, f"SmartExamSeat dataset from {name}")
    with _LOCK:
        engine().load_dataset(path, label=name)
        _CACHE.clear()
        _LAYOUTS.clear()
    return {"ok": True, "dataset": name, "file": os.path.relpath(path, HERE),
            "timetable": timetable,
            "summary": engine().catalogue()["summary"],
            "seconds": round(time.time() - started, 1)}


@app.route("/import")
def import_page():
    return render_template("import.html",
                           current=ENGINE.dataset if ENGINE else None)


@app.route("/api/import", methods=["POST"])
def api_import():
    """Upload a .toml config (form field `config`)."""
    upload = request.files.get("config")
    if not upload or not upload.filename:
        return jsonify({"ok": False, "message": "Choose a .toml config file."}), 400
    name = os.path.basename(upload.filename)
    if not name.endswith(".toml"):
        return jsonify({"ok": False, "message": "Upload a .toml config file."}), 400
    try:
        cfg = tomllib.loads(upload.read().decode("utf-8"))
        return jsonify(import_config(cfg, name))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as exc:
        return jsonify({"ok": False, "message": f"Not a valid TOML file: {exc}"}), 400
    except generate_data.GenerationError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400


# ---------------------------------------------------------------------------
# Constraints: add, remove, change, run
# ---------------------------------------------------------------------------

@app.route("/constraints")
def constraints_page():
    return render_template("constraints.html", dataset=engine().dataset)


@app.route("/api/constraints")
def api_constraints():
    with _LOCK:
        return jsonify(engine().constraints())


def _constraints_changed():
    # Plans made under the old rules are no longer valid answers.
    _CACHE.clear()


@app.route("/api/constraints", methods=["POST"])
def api_add_constraint():
    body = request.get_json(silent=True) or {}
    strength = body.get("strength", "hard")
    weight = body.get("weight", 1)
    try:
        with _LOCK:
            if body.get("custom"):
                c = body["custom"]
                out = engine().add_custom_rule(c.get("level", "seat"),
                                               (c.get("name") or "custom rule").strip(),
                                               c.get("rule", ""), strength, weight)
            else:
                out = engine().add_constraint((body.get("term") or "").strip(),
                                              strength, weight)
            _constraints_changed()
    except (ValueError, TypeError) as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(out), (200 if out.get("ok") else 400)


@app.route("/api/constraints/<int:cid>", methods=["DELETE"])
def api_remove_constraint(cid):
    with _LOCK:
        engine().remove_constraint(cid)
        _constraints_changed()
    return jsonify({"ok": True})


@app.route("/api/constraints/<int:cid>", methods=["PATCH"])
def api_set_strength(cid):
    body = request.get_json(silent=True) or {}
    try:
        with _LOCK:
            engine().set_strength(cid, body.get("strength", "hard"), body.get("weight", 1))
            _constraints_changed()
    except (ValueError, PrologError) as exc:
        return jsonify({"ok": False, "message": f"Cannot change it: {exc}"}), 400
    return jsonify({"ok": True})


@app.route("/api/constraints/reset", methods=["POST"])
def api_reset_constraints():
    with _LOCK:
        engine().reset_constraints()
        _constraints_changed()
    return jsonify({"ok": True})


@app.route("/api/evaluate", methods=["POST"])
def api_evaluate():
    with _LOCK:
        report = engine().evaluate()
        _CACHE.clear()               # the timetable was rebuilt
        _LAYOUTS.clear()
    return jsonify(report)


@app.route("/api/why", methods=["POST"])
def api_why():
    with _LOCK:
        out = engine().why_infeasible()
        _CACHE.clear()
    return jsonify(out)


# ---------------------------------------------------------------------------
# Planner: how many days, slots and rooms do these students need?
# ---------------------------------------------------------------------------

_TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def read_option(body: dict) -> tuple:
    """(days, slots, start, pool) from a planner request, checked."""
    days = int(body.get("days", 0))
    if not 1 <= days <= 60:
        raise ValueError("days must be between 1 and 60")
    slots = [(str(a), str(b)) for a, b in body.get("slots") or []]
    if not 1 <= len(slots) <= 6 or not all(_TIME.match(a) and _TIME.match(b)
                                           for a, b in slots):
        raise ValueError("give 1 to 6 slots as HH:MM times")
    start = str(body.get("start", ""))
    if not _DATE.match(start):
        raise ValueError("the start date must look like 2026-12-01")
    pool = []
    for p in body.get("pool") or []:
        r, c, n = int(p["rows"]), int(p["cols"]), int(p["count"])
        if not (1 <= r <= 40 and 1 <= c <= 40 and 0 <= n <= 60):
            raise ValueError("rooms: rows and cols 1-40, count 0-60")
        if n:
            pool.append((r, c, n))
    if not pool:
        raise ValueError("the room pool is empty")
    return days, slots, start, pool


@app.route("/planner")
def planner_page():
    return render_template("planner.html", dataset=engine().dataset)


@app.route("/api/plan/setup")
def api_plan_setup():
    """The loaded period and rooms, as the planner's starting point."""
    with _LOCK:
        cat = engine().catalogue()
    sessions = cat["sessions"]
    dates = sorted({s["date"] for s in sessions})
    slots = sorted({(s["start"], s["end"]) for s in sessions})
    groups: dict = {}
    for r in cat["rooms"]:
        if r["available"] == "yes":
            key = (r["rows"], r["cols"])
            groups[key] = groups.get(key, 0) + 1
    pool = [{"rows": r, "cols": c, "count": n}
            for (r, c), n in sorted(groups.items(), key=lambda kv: -kv[0][0] * kv[0][1])]
    return jsonify({"start": dates[0] if dates else "2026-12-01",
                    "days": len(dates), "slots": [list(s) for s in slots],
                    "pool": pool, "students": cat["summary"]["students"]})


@app.route("/api/plan/option", methods=["POST"])
def api_plan_option():
    body = request.get_json(silent=True) or {}
    try:
        days, slots, start, pool = read_option(body)
        weights = body.get("weights") or {}
        day_cost, room_cost = int(weights.get("day", 100)), int(weights.get("room", 50))
        if day_cost < 0 or room_cost < 0:
            raise ValueError("costs cannot be negative")
    except (ValueError, TypeError, KeyError) as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    with _LOCK:
        result = engine().plan_option(days, slots, start, pool, day_cost, room_cost)
    return jsonify(result)


@app.route("/api/plan/apply", methods=["POST"])
def api_plan_apply():
    try:
        days, slots, start, pool = read_option(request.get_json(silent=True) or {})
    except (ValueError, TypeError, KeyError) as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    with _LOCK:
        engine().apply_option(days, slots, start, pool)
        _CACHE.clear()
        _LAYOUTS.clear()
    return jsonify({"ok": True})


@app.route("/data")
def data_page():
    return render_template("data.html", dataset=engine().dataset)


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

@app.route("/api/dataset")
def api_dataset():
    return jsonify(engine().dataset_contents())


@app.route("/api/catalogue")
def api_catalogue():
    return jsonify(engine().catalogue())


@app.route("/api/generate", methods=["POST"])
def api_generate():
    session, years, majors = read_filters(request.get_json(silent=True) or {})
    if not session:
        return jsonify({"ok": False,
                        "error": {"message": "Pick an exam session first."}}), 400
    try:
        error = capacity_error(session, years, majors)
        if error:
            return jsonify({"ok": False, "error": error}), 400
        report = get_report(session, years, majors, refresh=True)
    except PrologError as exc:
        return jsonify({"ok": False, "error": {"message": str(exc)}}), 500
    return jsonify(report_to_json(report))


@app.route("/api/validate", methods=["POST"])
def api_validate():
    """Re-run A's validator over the plan currently on screen."""
    session, years, majors = read_filters(request.get_json(silent=True) or {})
    report = _CACHE.get(cache_key(session, years, majors))
    if report is None:
        return jsonify({"status": "no_plan",
                        "message": "Generate a plan first."}), 400
    if not report["ok"]:
        return jsonify({"status": "no_plan",
                        "message": "The last generation failed."}), 400
    with _LOCK:
        result = engine().validate(session, report["assignments"],
                                   years, majors)
    result["checked"] = len(report["assignments"])
    return jsonify(result)


@app.route("/api/session/<session>/cohorts")
def api_session_cohorts(session):
    """Per-cohort headcounts and seat capacity for the selection counter."""
    with _LOCK:
        return jsonify(engine().session_cohorts(session))


@app.route("/api/term", methods=["POST"])
def api_term():
    """Seat every session of the term; coverage per (major, year)."""
    try:
        with _LOCK:
            return jsonify(engine().term_report())
    except PrologError as exc:
        return jsonify({"error": {"message": str(exc)}}), 500


@app.route("/api/room/<room_id>")
def api_room(room_id):
    return jsonify(layout_of(room_id))


# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

def _report_for_export():
    session, years, majors = read_filters(request.args)
    if not session:
        return None, ("Pick an exam session first.", 400)
    error = capacity_error(session, years, majors)
    if error:
        return None, (error["message"], 400)
    report = get_report(session, years, majors)
    if not report["ok"]:
        return None, ("The seating plan could not be generated, "
                      "so there is nothing to export.", 409)
    return report, None


def _slug(report) -> str:
    filters = report["filters"]
    parts = [report["session"]]
    if filters["years"]:
        parts.append("y" + "".join(str(y) for y in sorted(filters["years"])))
    if filters["majors"]:
        parts.append("-".join(sorted(filters["majors"])))
    return "_".join(parts)


@app.route("/export/csv")
def export_csv():
    report, error = _report_for_export()
    if error:
        return error
    layouts = {room: layout_of(room) for room in report["rooms"]}
    body = export.seating_csv(report, layouts)
    return Response(
        body, mimetype="text/csv",
        headers={"Content-Disposition":
                 f'attachment; filename="seating_{_slug(report)}.csv"'})


@app.route("/export/rooms.csv")
def export_rooms_csv():
    report, error = _report_for_export()
    if error:
        return error
    body = export.room_list_csv(report)
    return Response(
        body, mimetype="text/csv",
        headers={"Content-Disposition":
                 f'attachment; filename="rooms_{_slug(report)}.csv"'})


@app.route("/export/pdf")
def export_pdf():
    import io

    report, error = _report_for_export()
    if error:
        return error
    only = request.args.get("room")
    rooms = [only] if only else sorted(report["rooms"])
    layouts = {room: layout_of(room) for room in rooms}

    info = None
    for s in engine().catalogue()["sessions"]:
        if s["id"] == report["session"]:
            info = s
            break

    pdf = export.seating_pdf(report, layouts, info, rooms)
    name = f"seating_{_slug(report)}" + (f"_{only}" if only else "") + ".pdf"
    return send_file(io.BytesIO(pdf), mimetype="application/pdf",
                     as_attachment=True, download_name=name)


# ---------------------------------------------------------------------------

def main() -> None:
    global ENGINE

    ap = argparse.ArgumentParser(description="SmartExamSeat web UI")
    ap.add_argument("--dataset", default=None,
                    help="start with this data file (e.g. data.pl); "
                         "default: start empty and import a config")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    print("loading Prolog knowledge base ...")
    if args.dataset:
        ENGINE = SeatingEngine(dataset=args.dataset)
        summary = ENGINE.catalogue()["summary"]
        print(f"  {summary['students']} students, {summary['subjects']} subjects, "
              f"{summary['sessions']} sessions, "
              f"{summary['rooms_available']} available rooms, "
              f"{summary['seats']} seats")
    else:
        ENGINE = SeatingEngine(empty=True)
        print("  no data yet: open the page and import a config")
    print(f"  serving on http://{args.host}:{args.port}")

    # One Prolog engine, so keep Flask single-threaded.
    app.run(host=args.host, port=args.port, debug=args.debug, threaded=False)


if __name__ == "__main__":
    main()
