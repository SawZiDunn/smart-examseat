#!/usr/bin/env python3
"""
app.py - the admin web UI for SmartExamSeat (Member C).

    python3 app.py                      # http://127.0.0.1:5000
    python3 app.py --dataset data_sample.pl
    python3 app.py --port 8080

The admin picks a session plus optional year/major filters, presses Generate,
and gets the seat grid for each room, a student list, the validator report,
and CSV / PDF downloads.

All Prolog work happens in bridge.py; this file only serves HTTP.
"""

from __future__ import annotations

import argparse
import threading

from flask import (Flask, jsonify, render_template, request, Response,
                   send_file)

import export
from bridge import SeatingEngine, PrologError

app = Flask(__name__)

ENGINE: SeatingEngine | None = None
_LOCK = threading.Lock()
_CACHE: dict = {}            # key -> report, so exports reuse the shown plan
_LAYOUTS: dict = {}          # room_id -> layout, fetched once


def engine() -> SeatingEngine:
    if ENGINE is None:                                   # pragma: no cover
        raise RuntimeError("engine not started")
    return ENGINE


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
                    help="data.pl (default) or data_sample.pl")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    print("loading Prolog knowledge base ...")
    ENGINE = SeatingEngine(dataset=args.dataset)
    summary = ENGINE.catalogue()["summary"]
    print(f"  {summary['students']} students, {summary['subjects']} subjects, "
          f"{summary['sessions']} sessions, "
          f"{summary['rooms_available']} available rooms, "
          f"{summary['seats']} seats")
    print(f"  serving on http://{args.host}:{args.port}")

    # One Prolog engine, so keep Flask single-threaded.
    app.run(host=args.host, port=args.port, debug=args.debug, threaded=False)


if __name__ == "__main__":
    main()
