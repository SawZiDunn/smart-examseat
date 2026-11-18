# Testing SmartExamSeat

All commands run from the project root with the venv active:

```bash
cd smartexamseat
source .venv/bin/activate
```

## 1. How the system works, in the order things happen

1. **You describe the term** in `config.toml`: majors, year levels, how many students and subjects each (major, year) cohort has, the rooms, and the exam period (days × time slots = sessions).
2. **`make data`** generates the students and each cohort's own subjects. The **timetabling CSP** (`timetable.pl`) then puts every subject in a session. It guarantees that nobody has two exams at once and that no session holds more than 80% of the open seats, and it avoids giving a student two exams on one day.
3. **One session at a time**, the seating CSP gives everyone with an exam in that session a seat. Different subjects share rooms; students sitting the same subject never sit side by side in a row. You can narrow a run by year and major. The **counter** (*selected / seats*) will not let a selection exceed the open rooms.
4. **The whole term:** *Seat every session* in the UI (or `make term`) runs every session and shows a year × major table of exams seated per cohort. A cohort is finished when all of its exams are seated.

Every exam a student takes is in exactly one session, so seating every session seats every student for every exam.

Filters are `filters(Years, Majors)`. An empty list means "everyone":

| Filter | Who gets seated |
|---|---|
| `filters([], [])` | every student with an exam in the session |
| `filters([1], [])` | only year 1 |
| `filters([], [se, ce])` | only SE and CE students, any year |
| `filters([1, 2], [se, ce])` | SE and CE students in year 1 or 2 |

## 2. Automated tests

```bash
make test            # everything (68 Prolog + 59 Python)
make test-prolog     # plunit only:  swipl -q -g run_tests -t halt tests/test_prolog.pl
make test-python     # bridge, web app, export and config tests
```

| Suite | File | What it proves |
|---|---|---|
| `dataset` | `tests/test_prolog.pl` | the data has no exam clashes, seats match room sizes, every session has enough accessible seats |
| `selection` | 〃 | year and major filters pick the right students |
| `allocation` | 〃 | each student goes to exactly one room, no room is over capacity, closed rooms are unused, cohort fit prefers a tight room, and reallocation keeps everyone |
| `solver` | 〃 | one seat per student, no shared seats, accessibility, separation; reports capacity failures, proven `no_solution` and `search_limit` distinctly |
| `validator` | 〃 | accepts a good plan; catches 9 kinds of injected violation |
| `pipeline_sample` / `pipeline_full` | 〃 | end to end: every session of the full dataset solves and validates; sess1 seats 585 students in six rooms with at most one retry |
| `scenarios` | 〃 | the seating edge cases in section 5 succeed or fail as expected |
| `timetable` | 〃 | the timetable is clash-free and within capacity; each failure reason is reported |
| `term` | 〃 | cohort counts add up, capacity counts only open rooms, the whole term finishes every cohort |
| Python | `tests/test_pipeline.py` | term parser, bridge results agree with Prolog, CSV/PDF exports, every web endpoint, over-capacity refusal, whole-term endpoint, config parsing |

## 3. Console testing (no browser)

**Every session, one line each:**
```bash
make demo
```

**The whole term, with the coverage grid:**
```bash
make term
```
```
Exams seated per cohort (seated/total, ! = not finished)
major   year 1      year 2      year 3      year 4
BME     225/225     225/225     200/200     200/200
...
SE      300/300     165/165     200/200     180/180
```

**One session in detail**, or one room drawn as a grid:
```bash
swipl -q -g "demo_session(sess1)" -t halt demo.pl
swipl -q -g "demo_room(sess1, r101)" -t halt demo.pl
```

**Through the Python bridge**, which is what the UI uses. It supports filters, another dataset and a room grid:
```bash
python3 bridge.py sess1
python3 bridge.py sess2 --years 1,2 --majors se,ce
python3 bridge.py sess1 --dataset data_sample.pl --room r101
```

**Interactively in Prolog:**
```prolog
$ swipl main.pl
?- generate_seating(sess1, filters([1,2], [se,ce]), R), print_result(R).
?- session_cohorts(sess1, C).            % who sits sess1, per cohort
?- selection_size(sess1, filters([1],[]), N, Accessible).
?- total_capacity(Seats, AccessibleSeats).
?- build_timetable([fill(80)], R).       % re-run the timetabler on the loaded data
?- use_sample_data.                      % switch to the 20-student dataset
?- use_full_data.                        % and back
```

## 4. Web UI checklist

```bash
make run                 # full dataset  -> http://127.0.0.1:5000
make run-sample          # 20-student dataset
python3 app.py --dataset tests/scenarios/not_enough_seats.pl   # any data file
```

Open `http://127.0.0.1:5000/?view=term` to go straight to the whole-term view.

**Selection counter**
- [ ] Picking a session shows *selected / seats* and the accessible count; the year and major chips show how many students each one covers
- [ ] Ticking chips changes the counter
- [ ] On `not_enough_seats.pl` (10 students, 8 seats), nothing ticked shows the counter in red and **Generate** is disabled; ticking one major brings it under the limit, and chips that would push it back over are greyed out

**One session**
- [ ] `sess1`, no filters: about 585 students in 6 rooms; the validator says valid
- [ ] Tick year 1 and major SE: the counts drop and only those students appear
- [ ] Room tabs: same-exam students never sit side by side; accessible students sit in the marked seats
- [ ] Search the student list for an ID and find their room and seat
- [ ] **Validate** gives the same verdict as the generate step
- [ ] Download the CSV, room-summary CSV and PDF, and open each one
- [ ] With a failing scenario file, the page shows a readable reason, not a crash

**Whole term**
- [ ] **Seat every session**: 16 / 16 sessions seated, and every cohort cell is green with seated = total
- [ ] Clicking a session row opens that session's seating plan

## 5. Edge-case datasets (`tests/scenarios/`)

Each file is a tiny world you can check by hand. The header comment in each file says what it tests and what result to expect.

**Seating** (the file already has a timetable). Run one with:
```bash
python3 bridge.py sess1 --dataset tests/scenarios/<name>.pl
```

| File | Setup | Expected result |
|---|---|---|
| `ok_two_exams.pl` | 2 exams, 12 students, one 3×4 room | ok, valid: the two exams take alternate columns |
| `two_sessions.pl` | exams in sess1 and sess2 | `sess1` seats 6 students, `sess2` seats 4 |
| `not_enough_seats.pl` | 10 students, 8 seats | failed: `not_enough_seats(r101, 10, 8)` |
| `not_enough_accessible.pl` | 3 accessible students, 2 accessible seats | failed: `not_enough_accessible(r101, 3, 2)` |
| `separation_impossible.pl` | 8 students of one exam in a 2×4 room | failed: `no_solution(r101)`. There are enough seats, but the separation rule allows only 4 |
| `closed_room.pl` | 8 students; 6 open seats plus a closed 12-seat room | failed: the closed room is never used |

**Timetabling** (the file has no timetable yet). Run one with:
```bash
SMARTEXAMSEAT_DATA=tests/scenarios/<name>.pl swipl -q -g "build_timetable([fill(100)], R), print(R), nl" -t halt main.pl
```

| File | Setup | Expected result |
|---|---|---|
| `tt_too_few_sessions.pl` | one cohort with 3 subjects, 2 sessions | `failed(too_few_sessions(3, 2))` |
| `tt_capacity.pl` | two cohorts with no shared students, 4 + 4 students, 10 seats | at `fill(60)` they are put in different sessions; at `fill(100)` they may share one |
| `tt_subject_too_large.pl` | 7 students of one subject, a 2×5 room | `failed(subject_too_large(se101, 7, 6))`: the separation rule allows only 6 of one exam |

All of these are also checked automatically by the `scenarios` and `timetable` blocks in `tests/test_prolog.pl`.

**Writing your own:** copy one of these files and edit the facts. The schema is in `details/CONTRACT.md` §3. Every student needs a `student/4`, a `student_name/2` and at least one `enrolled/2`. Every room needs a `room/4` and one `seat/4` per seat. To test seating, include `exam/2` facts, and make sure no student has two exams in the same session.

## 6. Changing the dataset: `config.toml`

Edit [`config.toml`](config.toml), then run:
```bash
make data            # = python3 generate_data.py --stats
```

| Setting | Default | Effect |
|---|---|---|
| `years` | `[1, 2, 3, 4]` | year levels |
| `[defaults] students` | `50` | students per (major, year) when a major does not say |
| `[defaults] subjects` | `5` | subjects per (major, year) when a major does not say |
| `[defaults] access_rate` | `0.03` | share of students who need an accessible seat |
| `[majors.<code>]` | 10 majors | one table per major. `students = 40` means 40 in every year; `students = [60, 55, 50, 45]` sets each year. The same goes for `subjects`. An empty table uses the defaults |
| `[exam_period]` | 8 days × 2 slots | `start_date`, `days` (weekdays; weekends are skipped), `slots` → the sessions |
| `[timetable] max_fill_percent` | `80` | the most of the open seats one session may use |
| `[[rooms.groups]]` | 16 rooms | `count`, `rows`, `cols`, `available` |
| `seed` | fixed | change it for a different random roster |

Example: year-1 SE has 5 subjects, year-2 SE has 3, and Civil year 1 has 4:
```toml
[majors.se]
subjects = [5, 3, 4, 4]

[majors.ce]
subjects = [4, 5, 5, 4]
```

If the exams can't fit, `make data` stops with a reason and leaves `data.pl` unchanged:
```
timetabling failed: The exams need at least 9 sessions but the exam period has 6.
Add exam days or rooms in config.toml.
```

Tested with the default students and rooms:

| `days` | Sessions | Result |
|---|---|---|
| 8 (default) | 16 | timetable built; busiest session at 41% of seats; every session seats and validates |
| 5 | 10 | timetable built; busiest session at 67% of seats; every session seats and validates |
| 3 | 6 | refused: at least 9 sessions are needed |

The 20-student `data_sample.pl` is fixed, defined in `build_sample()` in `generate_data.py`. The tests read their expected student and subject counts from `config.toml`, so changing the config does not break them, as long as the exams still fit.
