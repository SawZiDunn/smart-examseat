# SmartExamSeat: CONTRACT.md

Shared interface between Member A, B and C. **Frozen after kickoff.** Any change must be announced in the group chat immediately and edited here.

Paste this file into every AI coding agent as context.

---

## 1. Ownership

| Member | Owns | Files |
|---|---|---|
| **A** | Data, scheduling rules, room allocation, validator | `data.pl`, `rules.pl`, `allocation.pl`, `validator.pl`, `generate_data.py` |
| **B** | Seat CSP solver, main entry point | `solver.pl`, `main.pl` |
| **C** | pyswip bridge, UI, export | `bridge.py`, `app.py`, `export.py` |

`main.pl` consults all `.pl` files. The bridge loads only `main.pl`.

---

## 2. Naming conventions

- All Prolog atoms are lowercase with underscores.
- Student IDs: `s0001` to `s2000`
- Exam / subject codes: `cs101`, `ma201`, ...
- Session IDs: `sess1`, `sess2`, ...
- Room IDs: `r101`, `r102`, ...
- Majors: atoms like `se`, `cs`, `ee`
- Years: integers `1` to `4`
- Rows and columns: integers starting at `1`

---

## 3. Facts (Member A defines, everyone reads)

```prolog
student(Id, Major, Year, Access).      % Access = none | wheelchair | other_accessible
student_name(Id, Name).                % Name is an atom/string, used by the UI
subject(Code).
enrolled(Id, Code).
exam(Code, Session).                   % which session an exam happens in
session_time(Session, Date, Start, End).   % e.g. session_time(sess1, '2026-12-01', '09:00', '12:00')
room(RoomId, Rows, Cols, Available).   % Available = yes | no
seat(RoomId, Row, Col, SeatType).      % SeatType = normal | accessible
```

Rules for the data:
- A student has **at most one exam per session** (clash-free after A's check).
- Only `Available = yes` rooms are used.
- `Access \= none` students must get a seat with `SeatType = accessible`.

---

## 4. Shared data shapes

| Name | Shape |
|---|---|
| Filters | `filters(Years, Majors)`, both lists. Empty list = no filter (all). Example: `filters([1,2], [se,cs])` |
| Student entry | `s(StudentId, ExamCode)` |
| Assignment | `assign(StudentId, ExamCode, RoomId, Row, Col)` |
| Room group | `room_group(RoomId, [s(StudentId, ExamCode), ...])` |

---

## 5. Predicates

### 5.1 Member A: Data and allocation

```prolog
% All students sitting an exam in Session who match Filters.
% Students = [s(StudentId, ExamCode), ...]
students_in_session(+Session, +Filters, -Students).

% True if the student has two exams in the same session (clash). Used for data checks.
exam_clash(?StudentId, ?Session).

% Stage 1: split students across available rooms.
% Respects capacity and accessible-seat counts; balances rooms, spreads majors.
% Allocation = [room_group(RoomId, Students), ...]
allocate_rooms(+Session, +Students, -Allocation).

% Read back one room's group from the last allocation of this session.
students_for_room(+Session, +RoomId, -Students).

% Stage 1 retry: move students out of a failed room and return a new Allocation.
% Reason comes from the solver (see 5.2).
reallocate(+Session, +FailedRoomId, +Reason, -NewAllocation).

% Check a full result against all hard constraints.
% Report = valid | invalid([violation(Rule, Details), ...])
validate_seating(+Session, +Filters, +Assignments, -Report).
```

`Rule` is one of:
`one_seat_per_student`, `seat_unique`, `room_capacity`, `room_available`, `accessibility`, `exam_clash`, `separation`, `missing_student`.

### 5.2 Member B: Seat solver

```prolog
% Stage 2: assign seats inside ONE room (backtracking CSP).
% Result = ok(Assignments) | failed(Reason)
solve_room(+Session, +RoomId, +Students, -Result).
```

`Reason` is one of:

```prolog
not_enough_seats(RoomId, Needed, Have)
not_enough_accessible(RoomId, Needed, Have)
no_solution(RoomId)
search_limit(RoomId)
```

```prolog
% Main entry point. Calls A's students_in_session and allocate_rooms,
% runs solve_room for every room, retries failed rooms through reallocate/4
% (max_retries/1 capacity-first attempts, then room fallback), collects all
% assignments. Further room additions stop when no unused room remains.
% Result = ok(Assignments) | failed(Reason)
generate_seating(+Session, +Filters, -Result).
```

### 5.3 Helper predicates for the UI (Member A provides)

```prolog
list_sessions(-Sessions).              % [sess1, sess2, ...]
list_majors(-Majors).                  % [se, cs, ...]
list_years(-Years).                    % [1,2,3,4]
room_layout(+RoomId, -Rows, -Cols, -Seats).   % Seats = [seat(Row, Col, SeatType), ...]
```

---

## 6. Constants

```prolog
min_separation(1).     % same-exam students need >= 1 empty seat between them in the same row
max_retries(3).        % capacity-first reallocations before room fallback
```

Defined in `rules.pl`. Meaning: two students of the same exam in the same row must have a column distance of at least `min_separation + 1`.

---

## 7. Member C: bridge usage (pyswip)

```python
from pyswip import Prolog
prolog = Prolog()
prolog.consult("main.pl")

# Example call
q = "generate_seating(sess1, filters([1,2],[se,cs]), Result)"
result = list(prolog.query(q))[0]["Result"]
# ok([assign(s0001, cs101, r101, 1, 1), ...])  or  failed(Reason)
```

C parses `ok(...)` / `failed(...)` into Python objects. C runs `validate_seating/4` after every successful generation and shows the report.

---

## 8. Development order and mock data

1. **Kickoff:** all three agree on this file.
2. **A first delivers a tiny sample dataset** (~20 students, 2 rooms, 1 session) in `data.pl`, then builds the full generator (~10 majors, 2,000 students, ~50 subjects, 10 to 20 rooms).
3. **B** starts `solve_room` on the tiny sample, then `generate_seating` once A's `allocate_rooms` exists.
4. **C** starts the UI shell with a hardcoded `ok([...])` result in the shape above, then swaps in the real bridge once `generate_seating` returns anything.
5. **All:** integrate, fix errors, route bugs to the owner.

---

## 9. Bug routing

| Symptom | Owner |
|---|---|
| Wrong or missing students, clash, bad dataset, bad room split | A |
| Seat conflicts, constraint violations, solver timeout | B |
| UI, parsing, export problems | C |
| Validator reports a violation | A confirms the validator is right, then B or A fixes the source |

---

## 10. Change log

| Date | Change | By |
|---|---|---|
| | Initial contract | All |
| 2026-11-15 | `main.pl` is **not** a module, so `prolog.consult("main.pl")` exposes `generate_seating/3` by plain name. | B |
| 2026-11-15 | Added `generate_seating/4` with `Stats = stats(Students, Rooms, Retries, Millis)` for the UI. `generate_seating/3` is unchanged. | B |
| 2026-11-15 | Added JSON helpers in `main.pl` for the bridge: `seating_report_json/3` (plan + validator report + stats), `generate_seating_json/3`, `catalogue_json/1`, `room_layout_json/2`. The raw `ok(...)` / `failed(...)` route of section 7 still works and the tests exercise both. | B, C |
| 2026-11-15 | A also provides `list_rooms/1`, `session_info/4`, `student_display/4`, `exams_in_session/2` and `forget_allocations/0` for the UI. | A |
| 2026-11-15 | `validator.pl` also exports `explain_violation/2`, turning a `violation/2` into a sentence for the UI. | A |
| 2026-11-15 | `solve_room/5` added with an `Options` list (`budget(N)`) for the tests; `solve_room/4` is unchanged. | B |
| 2026-11-15 | `rules.pl` exposes `max_same_exam_per_room/2` = `Rows * ceil(Cols/(min_separation+1))`, the ceiling on how many students of one exam a room can hold. The allocator uses it so it never hands B a provably unsolvable room. | A |
| 2026-11-15 | `data.pl` is generated; `data_sample.pl` holds the tiny set. `main.pl` loads `data.pl` by default, honours `$SMARTEXAMSEAT_DATA`, and exposes `use_sample_data/0` and `use_full_data/0`. | A |
| 2026-11-15 | Behaviour fix, no signature change: `allocate_rooms/3` never drops a student. Students the rooms cannot take go into the biggest room, so `solve_room/4` fails it with the exact reason and `generate_seating/3` returns `failed(Reason)` instead of an `ok` plan with students missing. `reallocate/4` no longer re-opens the room that just failed. | A |
| 2026-11-16 | Dataset is described in `config.toml` (students and subjects per major/year, rooms, exam period). Subjects now belong to one (major, year) cohort, codes `<major><year><nn>` e.g. `se103`. The fact schema in section 3 is unchanged. | A |
| 2026-11-16 | New `timetable.pl` (A): `build_timetable(+Options, -Result)` assigns each subject to a session (timetabling CSP). `Result = ok([Subject-Session, ...], stats(SameDayPairs, PeakLoad, Limit, Sessions)) \| failed(Reason)`, Reason one of `no_sessions`, `subject_too_large(S, Size, Max)`, `too_few_sessions(Need, Have)`, `no_timetable(N)`. Its output becomes the `exam/2` facts in `data.pl`. | A |
| 2026-11-16 | `rules.pl` exports `total_capacity(-Seats, -AccessibleSeats)` (open rooms only). `dataset_summary/1` now reports open seats. | A |
| 2026-11-16 | `main.pl` adds `session_cohorts/2`, `selection_size/4`, `session_cohorts_json/2` (selection counter) and `seat_term/2`, `term_report_json/1`, `print_term_report/0` (whole-term run with per-cohort coverage). The catalogue's sessions also carry `students`. | B |
| 2026-11-16 | UI/bridge: `GET /api/session/<id>/cohorts`, `POST /api/term`; `/api/generate` and the exports refuse a selection larger than the open seats (`over_capacity`) or the accessible seats (`over_accessible_capacity`). | C |
