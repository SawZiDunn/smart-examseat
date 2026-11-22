# Testing SmartExamSeat

All commands run from the project root with the venv active:

```bash
cd smartexamseat
source .venv/bin/activate
```

## 1. How the system works, in the order things happen

1. **You describe the term** in an Excel workbook (`datasets/big.xlsx` or `small.xlsx`): the students, the subjects of every (major, year), the rooms, the exam period (days × morning/afternoon slot = sessions) and a few settings. The **Summary** sheet counts it all per (major, year).
2. **`make data`** (or uploading the workbook in the UI) checks the sheets and enrols every student in their cohort's subjects. The **timetabling CSP** (`timetable.pl`) then puts every subject in a session. It guarantees that nobody has two exams at once and that no session holds more than 80% of the open seats, and it avoids giving a student two exams on one day.
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
make test            # everything (101 Prolog + 88 Python, about a minute and a half)
make test-prolog     # plunit only:  swipl -q -g run_tests -t halt tests/test_prolog.pl
make test-python     # bridge, web app, export and workbook tests
```

| Suite | File | What it proves |
|---|---|---|
| `dataset` | `tests/test_prolog.pl` | the data has no exam clashes, seats match room sizes, every session has enough accessible seats |
| `selection` | 〃 | year and major filters pick the right students |
| `allocation` | 〃 | each student goes to exactly one room, no room is over capacity, closed rooms are unused, cohort fit prefers a tight room, and reallocation keeps everyone |
| `solver` | 〃 | one seat per student, no shared seats, accessibility, separation; reports capacity failures, proven `no_solution` and `search_limit` distinctly |
| `validator` | 〃 | accepts a good plan; catches 9 kinds of injected violation |
| `pipeline_sample` / `pipeline_full` | 〃 | end to end: every session of the full dataset solves and validates; sess1 seats everyone within the open rooms |
| `scenarios` | 〃 | the seating edge cases in section 5 succeed or fail as expected |
| `timetable` | 〃 | the timetable is clash-free and within capacity; each failure reason is reported |
| `term` | 〃 | cohort counts add up, capacity counts only open rooms, the whole term finishes every cohort |
| `constraints` | 〃 | the default set; malformed constraints are refused; separation(2), no separation, column_gap and room_closed change the plan as they should; the validator checks added hard constraints; a custom Prolog rule prunes the search; unsafe rules are refused; soft penalty = weight x violations; the blame analysis names the culprit |
| `timetable_constraints` | 〃 | no_exam_on, fixed_session and a custom timetable rule are obeyed; too few days is proven without search |
| `planner` | 〃 | weekdays skip weekends; an option is scored (days x cost + rooms x cost + penalty) and the loaded setup restored; a too-small pool is refused; unused rooms are not counted; applying an option replaces the setup |
| Python | `tests/test_pipeline.py` | term parser, bridge results agree with Prolog, CSV/PDF exports, every web endpoint, over-capacity refusal, whole-term endpoint, workbook reading and import |

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
SE      250/250     150/150     200/200     180/180
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
make run                 # starts empty -> http://127.0.0.1:5000 opens the Import page
python3 app.py --dataset data.pl                               # skip the import, use data.pl
make run-sample          # 20-student dataset
python3 app.py --dataset tests/scenarios/not_enough_seats.pl   # any data file
```

**Import**
- [ ] `make run`, open the page: it goes straight to *Import*, with the upload box and download links for `small.xlsx` and `big.xlsx`
- [ ] Upload `datasets/small.xlsx`: about a second later the data page opens with 120 students and 6 sessions
- [ ] *Change dataset* (top right), upload `datasets/big.xlsx`: 1,925 students, 20 sessions
- [ ] Open a copy of `small.xlsx`, set *Exam days* to 1 on the **Exam period** sheet, upload it: a readable refusal ("needs at least 3 sessions"), and the previous data stays loaded
- [ ] In a copy, type `two` as a Year on **Students** and `maybe` as Available on **Rooms**: the refusal lists both, with sheet and row
- [ ] Upload a `.toml` or `.csv`: refused, asking for an `.xlsx`
- [ ] The workbooks and `data.pl` are unchanged afterwards (`git status`)

Open `http://127.0.0.1:5000/?view=term` to go straight to the whole-term view, or `/data` for the data page.

**Selection counter**
- [ ] Picking a session shows *selected / seats* and the accessible count; the year and major chips show how many students each one covers
- [ ] Ticking chips changes the counter
- [ ] On `not_enough_seats.pl` (10 students, 8 seats), nothing ticked shows the counter in red and **Generate** is disabled; ticking one major brings it under the limit, and chips that would push it back over are greyed out

**One session**
- [ ] `sess1`, no filters: 480 students in about 9 rooms; the validator says valid
- [ ] Tick year 1 and major SE: the counts drop and only those students appear
- [ ] Room tabs: each exam has its own colour; same-exam students never sit side by side; students marked **A** sit in the accessible seats
- [ ] Seats fill column by column, so each cohort sits as a block of columns
- [ ] Search the student list for an ID and find their room and seat
- [ ] **Validate** gives the same verdict as the generate step
- [ ] Download the CSV, room-summary CSV and PDF, and open each one
- [ ] With a failing scenario file, the page shows a readable reason, not a crash

**Data page** (the `data.pl → view data` button, top right)
- [ ] The cards match `make data --stats`: students, subjects, exam seats, sessions, rooms, seats
- [ ] **Cohorts**: one cell per (major, year) with its student count and its subjects, each with its session
- [ ] **Timetable**: days × slots; each session lists its subjects and cohorts, and the load bar never passes 80% of the seats
- [ ] Clicking a cohort (e.g. *SE Y1*) opens the seating page for just that cohort in that session; *Seat this session* seats everyone
- [ ] **Students**: search by ID or name, filter by major, year or accessible seat; every row lists the student's exams and sessions
- [ ] **Rooms**: every room with its size and accessible seats (dashed); closed rooms are greyed out

**Constraints** (top right, *Constraints*; examples in `CONSTRAINTS.md`)
- [ ] The page lists the four defaults as Prolog facts, and the six always-on rules
- [ ] Pick `column_gap(n)` in the catalogue, add it as hard, *Run*: feasible; the room grids on the seating page have empty rows between same-exam students
- [ ] Change a constraint from hard to soft and back; remove one; *Reset to defaults*
- [ ] Type `separation(x)` or `foo(1)`: a readable refusal, nothing added
- [ ] Click the example "no same major side by side", add it as soft weight 2, *Run*: feasible, with a penalty and example pairs
- [ ] Add `room_fill(30)` (small.xlsx), *Run*: not feasible; *Which constraint is to blame?* names `room_fill(30)`
- [ ] Add the example "year 1 students not in the front row" as hard: not feasible, and the blame table names both `accessible_seats` and the rule
- [ ] Write `violation(X) :- shell(ls), X = 1.` as a rule: refused ("shell/1 is not allowed")

**Planner** (top right, *Planner*)
- [ ] The form starts from the loaded data: first exam day, a range of days around the current one, the current slots, and the current rooms as the pool
- [ ] On `small.xlsx`: days 1-5, tick 1 and 2 slots a day, *Find the best*: 1 day and 2 days x 1 slot are refused with the reason (too few sessions); the best is 3 days (score 400)
- [ ] *+ Add a room size* adds a row; the option count and pool size update
- [ ] Raise *Cost per room needed* and run again: options with fewer rooms win more often
- [ ] *Use this option*: the Data page timetable now has the chosen days and slots, and the seating page uses the pool
- [ ] Add a constraint on the Constraints page (e.g. `no_exam_at('13:30')`) and run the planner again: the 2-slot options change

**Whole term**
- [ ] **Seat every session**: 20 / 20 sessions seated, and every cohort cell is green with seated = total
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

**Writing your own:** copy one of these files and edit the facts. The schema is in [README.md section 8.2](README.md#82-facts-datapl-generated). Every student needs a `student/4`, a `student_name/2` and at least one `enrolled/2`. Every room needs a `room/4` and one `seat/4` per seat. To test seating, include `exam/2` facts, and make sure no student has two exams in the same session.

## 6. Changing the dataset: the workbook

Edit the workbook in Excel, LibreOffice or Google Sheets (download it as
`.xlsx`), then upload it on the Import page. For the console tools and the
tests, `make data` reads `datasets/big.xlsx`:
```bash
make data                                            # datasets/big.xlsx -> data.pl
python3 generate_data.py --workbook my_term.xlsx     # any other workbook
```

| Sheet | What to change |
|---|---|
| **Students** | add, remove or edit rows: Student ID, Name, Major, Year, Access (`none` / `wheelchair` / `other_accessible`) |
| **Subjects** | one row per subject: Code, Major, Year. Every student of that major and year sits it |
| **Rooms** | Room ID, Rows, Columns, Available (`yes` / `no`) |
| **Exam period** | First exam day, Exam days (weekdays; weekends are skipped), the morning and afternoon times. Leave the afternoon empty for mornings only |
| **Settings** | Session fill % (default 80: the most of the open seats one session may use), Accessible front-row columns (`1, 3, 5, 7`) |
| **Summary** | nothing: it is worked out by formulas (if you add a new major or year, add a row for it to see its counts) |

A mistake is reported with its sheet and row, up to 15 at a time:
```
The workbook has problems:
- Students row 2: Year must be a whole number (1-8), got 'two'.
- Subjects row 14: ee105 is for EE year 1, but no student is in that major and year.
```

If the exams can't fit, the import (or `make data`) stops with a reason and
keeps the previous data:
```
timetabling failed: The exams need at least 15 sessions but the exam period has 14.
Add exam days or rooms, or relax a constraint.
```

Tested with `big.xlsx` and its rooms, changing *Exam days*:

| Exam days | Sessions | Result |
|---|---|---|
| 12 | 24 | timetable built; busiest session at 48% of seats; every session seats and validates |
| 10 (default) | 20 | timetable built; busiest session at 59% of seats; every session seats and validates |
| 8 | 16 | timetable built (72% of seats), but about half the sessions fail to seat with `search_limit`: rooms are too full for the separation rule |
| 7 | 14 | refused: at least 15 sessions are needed |

### The small demo dataset: `datasets/small.xlsx`

Easy to picture, for demos. Upload it on the Import page (or *Change dataset*):

|        | SE | CS | EE |
|---|---|---|---|
| year 1 | 30 students, 3 subjects | 30 students, 3 subjects | - |
| year 2 | 20 students, 2 subjects | 20 students, 2 subjects | 20 students, 2 subjects |

120 students, 12 subjects, 3 exam days x 2 slots = 6 sessions, 2 rooms of
8x8 (128 seats). For the console tools:

```bash
python3 generate_data.py --workbook datasets/small.xlsx && make demo
make data                      # afterwards: back to the main set
```

While the small set is in `data.pl`, some tests fail, because they expect the
main dataset. Run `make data` before `make test`.

The timetable it produces puts each year-1 student's 3 exams on 3 different
days and seats every session in 1-2 rooms with no retries.

### New random workbooks

`datasets/big.toml` and `small.toml` are recipes: counts per (major, year),
rooms, exam period and a random seed. `make workbooks` turns them into
`big.xlsx` and `small.xlsx` with random names (the same ones every time, as
the seed is fixed). Use this only for test data; real data goes straight
into a workbook.

### The test sample

The 20-student `data_sample.pl` is fixed, defined in `build_sample()` in `generate_data.py`. The tests read their expected student and subject counts from `datasets/big.xlsx`, so changing the workbook does not break them, as long as the exams still fit.
