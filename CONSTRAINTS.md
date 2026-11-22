# Constraints: what you can add, and how to write your own

Open **Constraints** at the top right of the app. Every rule the system obeys,
apart from the six that define what a seating plan is, is a **Prolog fact** you can
add, remove or change while the app runs:

```prolog
active(1, separation(1),        hard).       % the default set
active(2, accessible_seats,     hard).
active(3, session_fill(80),     hard).
active(4, max_exams_per_day(1), soft(10)).
```

- **hard**: the plan is only valid if the rule holds. The search prunes on it:
  a seat or session that breaks it is never tried.
- **soft(W)**: the rule may be broken. Every violation adds `W` to the
  plan's **penalty**, and the search tries the cheaper seats and sessions first.

Press **Run with these constraints**. The app then:
1. builds a new timetable;
2. seats every session;
3. checks every hard rule again, independently;
4. adds up the soft penalties.

If the plan is not feasible, **Which constraint is to blame?** turns each hard
constraint off in turn and tells you which ones make it feasible.

The **Planner** page uses the same active constraints for every option it
tries, so you can also ask "with these rules, how many days and rooms do we need?".

Always on (they define a seating plan, so they cannot be removed): one seat per
student per exam, no shared seats, no room over its size, rooms marked
unavailable in the data are never used, everyone gets a seat, and no student has two
exams in the same session.

---

## 1. Built-in constraints

Pick one in **Add a constraint**, or type the term directly.

### Seating (checked for every seat the solver tries)

| Type this | Meaning | Hard / soft |
|---|---|---|
| `separation(1)` | same-exam students in a row have at least 1 empty seat between them (the default) | both |
| `separation(2)` | the same with 2 empty seats: stricter, and needs more rooms | both |
| `column_gap(1)` | same-exam students in a column have at least 1 empty row between them | both |
| `no_diagonal` | same-exam students are never diagonal neighbours | both |
| `different_major_neighbours` | students side by side in a row are from different majors | both |
| `accessible_seats` | students who need an accessible seat get one (the default) | both |

### Rooms

| Type this | Meaning | Hard / soft |
|---|---|---|
| `room_fill(80)` | use at most 80% of the seats of any room | hard |
| `room_closed(r105)` | never use room r105 | hard |
| `cohort_together` | keep each exam in as few rooms as possible, with a penalty per extra room | soft |

### Timetable (checked when a subject is put in a session)

| Type this | Meaning | Hard / soft |
|---|---|---|
| `session_fill(80)` | a session holds at most 80% of the open seats (the default) | hard |
| `max_exams_per_day(1)` | no student has more than 1 exam on a day (soft by default) | both |
| `no_back_to_back` | no student has the morning and the afternoon exam on the same day | both |
| `no_exam_on('2026-12-03')` | no exams on that date | hard |
| `no_exam_at('13:30')` | no afternoon exams at all | hard |
| `fixed_session(se101, sess3)` | se101 must be in sess3 | hard |

Dates and times need quotes (`'2026-12-03'`, `'13:30'`). The picker adds them for you.

---

## 2. Writing your own rule in Prolog

A rule says **what is not allowed**. Write one or more clauses of the form

```prolog
violation(Witness) :- Body.
```

`Body` is true wherever the plan breaks your rule, and `Witness` is what the
app shows as the example, e.g. the two students involved. Choose:

- **Seating rule**: sees the seat plan (who sits where).
- **Timetable rule**: sees the timetable (which exam is in which session).

Then choose hard or soft. A hard rule is checked after **every** seat (or
session) the search tries, exactly like a built-in one.

### What a rule can use

**Seating rules**

| Predicate | True when |
|---|---|
| `seated(S, Exam, Room, Row, Col)` | student `S` sits `Exam` in `Room` at `Row`, `Col` |
| `next_to(S1, S2)` | `S1` and `S2` sit side by side in a row |
| `behind(S1, S2)` | `S2` sits directly behind `S1` |
| `diagonal(S1, S2)` | they are diagonal neighbours |
| `same_exam(S1, S2)` | they sit the same exam |
| `seat_type(Room, Row, Col, Type)` | `Type` is `normal` or `accessible` |
| `room_size(Room, Rows, Cols)` | the size of a room |

**Timetable rules**

| Predicate | True when |
|---|---|
| `exam_session(Exam, Session)` | `Exam` is held in `Session` |
| `takes(S, Exam)` | student `S` is enrolled in `Exam` |
| `session_date(Session, Date)` | e.g. `'2026-12-01'` |
| `session_start(Session, Time)` | e.g. `'09:30'` |
| `session_weekday(Session, Day)` | `mon`, `tue`, `wed`, `thu`, `fri`, `sat`, `sun` |
| `session_index(Session, N)` | 1 for the first session, 2 for the next, ... |
| `exam_size(Exam, N)` | `N` students sit `Exam` |

**Both**

| Predicate | True when |
|---|---|
| `student(S, Major, Year, Access)` | `Access` is `none`, `wheelchair` or `other_accessible` |
| `major(S, M)`, `year(S, Y)` | the student's major (`se`, `cs`, ...) and year |
| `needs_accessible(S)` | the student needs an accessible seat |
| `exam_cohort(Exam, Major, Year)` | the exam belongs to that cohort, e.g. `exam_cohort(se101, se, 1)` |

Plus `,` `;` `->` `\+`, comparisons (`=`, `\=`, `==`, `\==`, `@<`, `<`, `=<`,
`>`, `>=`, `=:=`, `=\=`), `is`, `member/2`, `between/3`, `atom_concat/3`,
`sub_atom/5`. Anything else (files, `assert`, `shell`, ...) is refused, so a
rule can only look at the plan.

**Tip:** with two students, add `S1 @< S2` so each pair is counted once.

### Seating examples

```prolog
% No two students of the same major side by side.        (hard or soft)
violation(S1-S2) :-
    next_to(S1, S2),
    major(S1, M), major(S2, M),
    S1 @< S2.
```

```prolog
% Nobody directly behind someone sitting the same exam.  (hard)
violation(S1-S2) :-
    behind(S1, S2),
    same_exam(S1, S2).
```

```prolog
% Prefer neighbours from different years.                (soft, e.g. weight 1)
violation(S1-S2) :-
    next_to(S1, S2),
    year(S1, Y1), year(S2, Y2),
    Y1 =\= Y2.
```
Read it carefully: this counts neighbours from *different* years. Swap `=\=`
for `=:=` to penalise the *same* year instead. A rule says what is not allowed.

```prolog
% Keep the first and last column empty (e.g. aisles).    (hard)
violation(S) :-
    seated(S, _, R, _, Col),
    room_size(R, _, Cols),
    ( Col =:= 1 ; Col =:= Cols ).
```

```prolog
% Accessible students only on accessible seats, written by hand.
% It is the same as the built-in accessible_seats, which shows that the
% built-in rules are ordinary Prolog too.
violation(S) :-
    needs_accessible(S),
    seated(S, _, R, Row, Col),
    seat_type(R, Row, Col, normal).
```

### Timetable examples

```prolog
% No year-1 exams on Friday.                             (hard)
violation(E) :-
    exam_session(E, S),
    exam_cohort(E, _, 1),
    session_weekday(S, fri).
```

```prolog
% Year-4 exams only in the morning.                      (hard)
violation(E) :-
    exam_session(E, S),
    exam_cohort(E, _, 4),
    session_start(S, T), T \== '09:30'.
```

```prolog
% Nothing from SE in the very first session.             (hard)
violation(E) :-
    exam_session(E, S),
    exam_cohort(E, se, _),
    session_index(S, 1).
```

```prolog
% Big exams (over 40 students) preferably not in the afternoon.  (soft)
violation(E) :-
    exam_session(E, S),
    exam_size(E, N), N > 40,
    session_start(S, '13:30').
```

```prolog
% One major's exams never share a session.               (hard)
violation(E1-E2) :-
    exam_session(E1, S), exam_session(E2, S),
    E1 @< E2,
    exam_cohort(E1, M, _), exam_cohort(E2, M, _).
```

```prolog
% se101 must be the first exam of year-1 SE.             (hard)
violation(se101-E) :-
    exam_session(se101, S1), exam_session(E, S2),
    exam_cohort(E, se, 1), E \== se101,
    session_index(S1, I1), session_index(S2, I2),
    I2 < I1.
```

---

## 3. Things to show (on `datasets/small.xlsx`)

Each one is a few clicks. Press **Run** after every change.

| Try | What you will see |
|---|---|
| Run with the defaults | feasible, penalty 0, every session seated |
| Remove `separation(1)` | same-exam students may now sit side by side (check a room on the seating page) |
| Add `separation(2)` and remove `separation(1)` | **not feasible** in two sessions (2 empty seats between same-exam students is too tight for the two 8×8 rooms). *Which constraint is to blame?* names `separation(2)` |
| Add `cohort_together` as soft, weight 3 | the penalty shows which exams are split over rooms |
| Add `no_exam_at('13:30')` | all exams move to the mornings: 3 sessions, nearly full |
| Change `max_exams_per_day(1)` to **hard**, then add `no_exam_on('2026-12-03')` | **not feasible**: year-1 students have 3 exams but only 2 days are left (proven by a lower bound, without searching) |
| Add `room_fill(30)` | **not feasible**: press *Which constraint is to blame?* and it names `room_fill(30)` |
| Add the rule "year 1 students not in the front row" (an example button) as hard | **not feasible**: the blame table names both `accessible_seats` and your rule, because the accessible seats are in the front row. Remove either one and it works. |
| Add "no same major side by side" as **soft**, weight 2 | feasible, with a penalty, and examples of the pairs that break it |

---

## 4. When a rule is refused

| Message | Fix |
|---|---|
| `Unknown constraint foo(1)` | check the spelling in the table above |
| `separation: x must be a whole number >= 0` | fill in a number |
| `no session on '2026-12-31'` | use a date from the exam period (see the Data page) |
| `room_fill can only be hard` | some constraints have no soft version |
| `shell/1 is not allowed in a seat rule` | only the predicates listed above can be used |
| `Prolog syntax error` | check the commas, brackets and the full stop at the end |
| `Each clause must look like violation(W) :- ...` | the head must be `violation(Something)` |
