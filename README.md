# SmartExamSeat

University exam seating arrangement planner, written as a **Constraint
Satisfaction Problem in Prolog** with a Python/Flask admin interface.

01286342 Artificial Intelligence &middot; Software Engineering, KMITL

| | |
|---|---|
| 67011158 | Kyi Thant Sin |
| 67011619 | May Nyein Chan |
| 67011653 | Saw Zi Dunn |

```
config.toml ──▶ Data + Timetable ──▶ Allocation ──▶ Seat Solver ──▶ Validator ──▶ UI ──▶ CSV/PDF
                  (A, CSP #1)           (A)         (B, CSP #2)        (A)        (C)      (C)
```

---

## 1. What it does

**Before the term** - the administrator describes the faculty in
`config.toml`: how many students and how many subjects each (major, year)
cohort has, the rooms, and the exam period. `make data` generates the
students and each cohort's own subjects, then a **timetabling CSP** in Prolog
decides which session (time slot) every subject is examined in, so that no
student has two exams at once and no session holds more students than the
rooms can seat.

**For one session** (e.g. Tuesday 09:00-12:00) the administrator optionally
narrows the population by **year level** and **major**. A live counter shows
*selected / seats* and will not let the selection exceed the open rooms. The
system then:

1. finds every student sitting an exam in that session,
2. splits them across the available examination rooms (*allocation*),
3. finds a concrete seat for every student inside their room by
   **backtracking search over a CSP** (*seat solving*),
4. re-checks the finished plan against every hard constraint
   (*validation*), and
5. shows the seat grid per room and exports CSV / PDF.

**For the whole term**, *Seat every session* (or `make term`) runs every
session and shows a year x major table of exams seated per cohort, so the
administrator can see that every cohort is finished.

On the default config (1,940 students, 191 subjects, 16 sessions, 14 open
rooms) the timetable is built in about 0.2 s, each session of ~580 students
is seated and validated in about **20 ms**, and the whole term in under 1 s.

```
session    students    rooms     retries     validator
sess1      585         6         0           valid (20 ms)
sess2      580         6         0           valid (16 ms)
...
sess16     575         6         0           valid (14 ms)
```

---

## 2. Install and run

```bash
sudo apt install swi-prolog          # or: brew install swi-prolog
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

make data                            # config.toml -> data.pl (+ timetable)
python3 app.py                       # http://127.0.0.1:5000
```

Useful variants:

```bash
python3 app.py --dataset data_sample.pl   # the 20-student smoke-test set
make demo                                 # solve every session in the console
make term                                 # whole term + coverage per cohort
make test                                 # both test suites
```

Straight from the Prolog console, no Python involved:

```bash
swipl main.pl
?- generate_seating(sess1, filters([1,2],[se,cs]), R), print_result(R).
?- generate_seating(sess1, filters([],[]), ok(A)),
   validate_seating(sess1, filters([],[]), A, Report).
?- use_sample_data, generate_seating(sess1, filters([],[]), ok(A)),
   print_room(r101, A).
```

---

## 3. Files

| File | Owner | What it holds |
|---|---|---|
| `config.toml` | A | what to generate: students and subjects per (major, year), rooms, exam period |
| `generate_data.py` | A | builds the dataset from `config.toml`, runs the timetabler, re-checks clashes and capacity |
| `timetable.pl` | A | `build_timetable/2` - the exam timetabling CSP (subject -> session) |
| `data.pl` | A | generated facts, including the timetable as `exam/2` |
| `data_sample.pl` | A | 20 students, 2 exams, 2 rooms - used by the tests and for demos |
| `rules.pl` | A | constants (`min_separation/1`, `max_retries/1`) and shared derived rules |
| `allocation.pl` | A | `students_in_session/3`, `allocate_rooms/3`, `reallocate/4`, UI helpers |
| `validator.pl` | A | `validate_seating/4` - independent re-check of a finished plan |
| `solver.pl` | B | `solve_room/4` - the backtracking seat CSP for one room |
| `main.pl` | B | `generate_seating/3`, the retry loop, `seat_term/2` (whole term), capacity counts, JSON helpers |
| `bridge.py` | C | pyswip bridge + a small Prolog-term parser |
| `app.py` | C | Flask admin UI and the export endpoints |
| `export.py` | C | CSV and PDF generation |
| `templates/`, `static/` | C | the web front end |
| `demo.pl` | all | console demonstration |
| `tests/test_prolog.pl` | all | 68 plunit tests |
| `tests/scenarios/` | all | tiny edge-case datasets for seating and timetabling |
| `TESTING.md` | all | every way to test the system, and how to change the dataset size |
| `tests/test_pipeline.py` | all | 59 Python tests (bridge, UI, exports, config, capacity) |

The shared interface between the three members is frozen in
[`details/CONTRACT.md`](details/CONTRACT.md).

---

## 4. The AI technique

The system solves **two CSPs in sequence**, both by backtracking search in
Prolog: first *which session* each subject is examined in (timetabling,
section 4.6, once per term), then *which seat* each student gets (seating,
sections 4.1-4.4, once per session).

### 4.1 The seat CSP

Per room:

* **Variables** - the students allocated to that room
* **Domains** - the seats of that room
* **Constraints** (all hard):

| Rule | Meaning |
|---|---|
| `one_seat_per_student` | every student gets exactly one seat |
| `seat_unique` | no seat holds two students |
| `room_capacity` | the seat exists and the room is not over-filled |
| `room_available` | closed rooms are never used |
| `accessibility` | `Access \= none` students only sit on `accessible` seats |
| `exam_clash` | nobody sits two exams in one session |
| `separation` | two students of the **same exam** in the **same row** must be at least `min_separation + 1 = 2` columns apart |
| `missing_student` | everyone who should sit the session is in the plan |

### 4.2 Backtracking search

`solver.pl` walks the student list recursively. For each student it picks a
seat with `member/2` and immediately checks the constraints; if a later
student cannot be placed, Prolog backtracks into that `member/2` and tries
the next seat. This is textbook chronological backtracking, expressed
directly as Prolog's own search:

```prolog
assign([s(StudentId, Code) | Rest], RoomId, AccessSeats, NormalFirst,
       Used, Rows, Acc, Out) :-
    domain(StudentId, AccessSeats, NormalFirst, Domain),
    member(seat(Row, Col, Type), Domain),
    \+ get_assoc(Row-Col, Used, _),                      % seat_unique
    rules:seat_fits(StudentId, Type),                    % accessibility
    exam_row_cols(Code, Row, Rows, Cols),
    rules:separation_ok(Row, Col, Cols),                 % separation
    ...
```

### 4.3 Heuristics

| Heuristic | Where | Why |
|---|---|---|
| most constrained student first | `solver.pl` | accessible students have a domain of 4 seats instead of 144, so they are placed first |
| largest exam group first, kept contiguous | `solver.pl` | the group the separation rule squeezes hardest gets the clean columns 1, 3, 5, … and the next exam fills the gaps |
| normal seats before accessible ones | `solver.pl` | stops ordinary students from eating the scarce accessible seats |
| open the fewest rooms that can hold the cohort | `allocation.pl` | minimises unused seats and the number of invigilated rooms |
| deal to the room with the most free space | `allocation.pl` | balances occupancy across the opened rooms |
| interleave by exam, then by major | `allocation.pl` | spreads majors and guarantees every room gets a mix of exams, which is what makes the separation rule satisfiable |
| per-room cap of `Rows × ceil(Cols/2)` students per exam | `rules.pl` | the allocator can prove in advance that a room is not impossible before the solver wastes time on it |
| bounded inference budget | `solver.pl` | a hopeless room reports `no_solution/1` instead of hanging, which triggers reallocation |

### 4.4 Allocation retry loop

When `solve_room/4` fails it returns a *reason*:

```prolog
not_enough_seats(RoomId, Needed, Have)
not_enough_accessible(RoomId, Needed, Have)
no_solution(RoomId)
search_limit(RoomId)
```

`generate_seating/3` feeds that reason back into `reallocate/4`, which moves
students out of the broken room (accessible students for an accessibility
failure, members of the largest exam group otherwise). It tries available
capacity in existing rooms first. If bounded search and those reshuffles still
do not solve the plan, it adds a room as a final fallback. `search_limit/1`
means the search may have been inconclusive; it is not reported as a proven
`no_solution/1`. Room expansion stops when there are no unused rooms left.

### 4.5 Other Prolog techniques used

* **unification** throughout - `enrolled(Student, Code)` against the fact base
* **recursion** over students, seats and assignment lists
* **negation as failure** - `\+ get_assoc(Row-Col, Used, _)` for "seat free"
* **AVL maps** (`library(assoc)`) for the used-seat set and the per
  `(Exam, Row)` column lists, so each constraint check is `O(log n)`

### 4.6 The timetabling CSP

`timetable.pl` runs once, when the data is generated:

| | |
|---|---|
| **Variables** | every subject |
| **Domains** | the sessions of the exam period (`[exam_period]` in `config.toml`) |
| **Hard constraints** | two subjects that share a student go in different sessions (this is what guarantees the `exam_clash` rule); a session's headcount <= open seats x `max_fill_percent`; a session's accessible headcount <= accessible seats |
| **Soft constraints** | a student should not have two exams on the same day; the load should be spread evenly |

The same pattern as the seat solver: `member/2` over an ordered domain, with
a bounded inference budget.

| Heuristic | Why |
|---|---|
| largest subject first, then most conflicts | the hardest subjects to place go first (fail-first) |
| session with fewest same-day conflicts first | how the soft "one exam per day" rule is honoured without making it hard |
| then the emptiest session | least-constraining value: keeps room for the subjects still to come |
| lower-bound precheck | `too_few_sessions(Need, Have)` is proven without search: Need = max(subjects per student, ceil(exam seats / session capacity), ceil(accessible exam seats / accessible seats)) |

Failure reasons: `too_few_sessions(Need, Have)`, `subject_too_large(Subject,
Size, Max)`, `no_sessions`, `no_timetable(Sessions)`. The generator prints
these as plain sentences and refuses to write `data.pl`.

---

## 5. Validation

`validate_seating/4` deliberately **does not reuse the solver's bookkeeping**.
It re-derives everything from the raw facts, so a bug in `allocation.pl` or
`solver.pl` surfaces here rather than being silently agreed with. It returns

```prolog
valid
invalid([violation(Rule, Details), ...])
```

and `explain_violation/2` turns each one into a sentence for the UI, e.g.

```
s0012 and s0045 both sit cs101 in r101 row 3 at columns 4 and 5 (distance 1, need 2)
```

The web UI runs the validator automatically after every generation and the
**Validate plan** button re-runs it on demand over the plan being displayed.

---

## 6. Tests

```bash
make test
```

For every way to test (console, UI checklist, edge-case datasets, changing
the dataset size) see [`TESTING.md`](TESTING.md).

* `tests/test_prolog.pl` - 68 plunit tests: dataset integrity, filters,
  allocation invariants, solver success and each of its three failure
  reasons, nine *injected* violations the validator must catch, the
  edge-case datasets in `tests/scenarios/`, the timetabler (clash-free,
  within capacity, and each failure reason), and the whole-term run.
* `tests/test_pipeline.py` - 59 tests: the Prolog-term parser, the bridge
  (both the raw `ok(...)`/`failed(...)` route and the JSON route), every
  session solving and validating, CSV/PDF output, every HTTP endpoint, the
  capacity check, the whole-term endpoint, and config parsing.

---

## 7. Dataset shape

Everything below comes from `config.toml`; edit it and run `make data`.

| | default config |
|---|---|
| majors | 10: SE, CE, CS, EE, EME, ME, RAI, ENE, IE, BME (lowercase codes in the data, uppercase on screen) |
| year levels | 1-4 |
| students | 1,940 - set per (major, year), default 50 |
| subjects | 191 - set per (major, year), default 5; each cohort has its **own** subjects (`se101`, `se102`, ... `ce203`) |
| enrolments | 9,245 - every student sits all of their cohort's subjects |
| sessions | 16: 8 weekdays x 2 slots from 2026-12-01 |
| rooms | 16 (14 available, 2 closed for maintenance) |
| seats | 1,432 in open rooms, of which 56 accessible |
| accessibility | ~3% of students; accessible seats at row 1, columns 1, 3, 5, 7 |
| peak session | 585 students, 41% occupancy (the timetabler caps it at 80%) |

**The clash-free invariant.** The timetabling CSP never puts two subjects
that share a student into the same session. `generate_data.py` re-checks
this independently before writing `data.pl`, as does the
`dataset:no_exam_clash` test.

---

## 8. Known limits

* Seating enforces hard constraints only. Soft preferences (same major
  sitting near each other, invigilator workload) are not modelled. The
  timetabler has two soft preferences (one exam per day per student, even
  load) expressed through value ordering.
* `min_separation(1)` applies inside a row only, which is the rule stated in
  the contract. Diagonal and front-to-back neighbours are unconstrained.
* The seating retry loop reshuffles rooms but never changes the timetable.
  The timetabler keeps each session within capacity, and the UI refuses a
  selection larger than the open rooms; if rooms are closed after the
  timetable is built, regenerate the data (`make data`).
* Subjects belong to exactly one cohort, as configured. The timetabler
  itself handles shared subjects (it works from who is enrolled in what),
  but the generator does not create electives.
* One SWI-Prolog engine per process, so `app.py` runs single-threaded and
  serialises requests behind a lock.
