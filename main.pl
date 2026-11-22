% ===========================================================================
% main.pl  -  entry point: loads everything and drives the pipeline  (B)
% ===========================================================================
%
%   Data (A) -> Allocation (A) -> Seat solver (B) -> Validator (A) -> UI (C)
%
% This file is deliberately NOT a module: the Python bridge does
%     prolog.consult("main.pl")
% and then calls generate_seating/3 and friends by plain name.
%
% Run from a shell:
%     swipl -q -g "generate_seating(sess1, filters([],[]), R), print_result(R)" \
%           -t halt main.pl
% ===========================================================================

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(http/json)).

:- dynamic project_dir/1.

% Remember where this file lives so the dataset can be found no matter what
% the current working directory is when the bridge loads us.
:- prolog_load_context(directory, Dir),
   retractall(project_dir(_)),
   assertz(project_dir(Dir)).

:- use_module(rules).
:- use_module(allocation).
:- use_module(solver).
:- use_module(validator).
:- use_module(timetable).
:- use_module(constraints).
:- use_module(custom_rules, [vocabulary/3]).
:- use_module(planner).

:- initialization(load_dataset).


% ===========================================================================
% Dataset loading
% ===========================================================================

%  SMARTEXAMSEAT_DATA=none starts with no data at all; the web UI then
%  loads one with load_data_file/1 after the admin imports a config.
load_dataset :-
    (   getenv('SMARTEXAMSEAT_DATA', File)
    ->  true
    ;   File = 'data.pl'
    ),
    (   File == none
    ->  true
    ;   load_data_file(File)
    ).

load_data_file(File) :-
    resolve(File, Path),
    retractall(user:student(_, _, _, _)),
    retractall(user:student_name(_, _)),
    retractall(user:subject(_)),
    retractall(user:enrolled(_, _)),
    retractall(user:exam(_, _)),
    retractall(user:session_time(_, _, _, _)),
    retractall(user:room(_, _, _, _)),
    retractall(user:seat(_, _, _, _)),
    allocation:forget_allocations,
    user:consult(Path).

resolve(File, Path) :-
    (   is_absolute_file_name(File)
    ->  Path = File
    ;   project_dir(Dir)
    ->  directory_file_path(Dir, File, Path)
    ;   Path = File
    ).

%! use_sample_data is det.
%  Switch to the 20-student smoke-test dataset (handy in the REPL).
use_sample_data :- load_data_file('data_sample.pl').

%! use_full_data is det.
use_full_data :- load_data_file('data.pl').

%! dataset_summary(-Summary) is det.
dataset_summary(dataset(Students, Subjects, Sessions, Rooms, Seats)) :-
    aggregate_all(count, user:student(_, _, _, _), Students),
    aggregate_all(count, user:subject(_), Subjects),
    aggregate_all(count, user:session_time(_, _, _, _), Sessions),
    aggregate_all(count, user:room(_, _, _, yes), Rooms),
    total_capacity(Seats, _).                % seats in AVAILABLE rooms


% ===========================================================================
% generate_seating/3  (README.md section 8.4)
% ===========================================================================

%! generate_seating(+Session, +Filters, -Result) is det.
%
%  Result = ok([assign(StudentId, ExamCode, RoomId, Row, Col), ...])
%         | failed(Reason)
%
%  1. ask A which students sit in this session,
%  2. ask A to split them across rooms,
%  3. run B's solver on every room,
%  4. on a room failure, ask A to reallocate and start step 3 again
%     (at most max_retries/1 times).
generate_seating(Session, Filters, Result) :-
    generate_seating(Session, Filters, Result, _Stats).

%! generate_seating(+Session, +Filters, -Result, -Stats) is det.
%  Stats = stats(Students, Rooms, Retries, Millis) - used by the UI.
generate_seating(Session, Filters, Result, Stats) :-
    get_time(T0),
    students_in_session(Session, Filters, Students),
    length(Students, NStudents),
    (   Students == []
    ->  Result = ok([]), Retries = 0, NRooms = 0
    ;   allocate_rooms(Session, Students, Allocation),
        max_retries(MaxRetries),
        solve_all_with_retry(Session, Allocation, MaxRetries, 0,
                             Result, Retries, NRooms)
    ),
    get_time(T1),
    Millis is round((T1 - T0) * 1000),
    Stats = stats(NStudents, NRooms, Retries, Millis),
    !.                         % one plan per call: no backtracking into it

solve_all_with_retry(Session, Allocation, Budget, Used, Result, Retries, NRooms) :-
    (   solve_all(Session, Allocation, [], Assignments)
    ->  Result = ok(Assignments),
        Retries = Used,
        length(Allocation, NRooms)
    ;   last_failure(FailedRoom, Reason),
        (   Budget > 0,
            reallocate(Session, FailedRoom, Reason, NewAllocation)
        ->  Budget1 is Budget - 1,
            Used1 is Used + 1,
            solve_all_with_retry(Session, NewAllocation, Budget1, Used1,
                                 Result, Retries, NRooms)
        ;   Budget =:= 0,
            reallocate_with_extra_room(Session, FailedRoom, Reason,
                                       NewAllocation)
        ->  Used1 is Used + 1,
            solve_all_with_retry(Session, NewAllocation, 0, Used1,
                                 Result, Retries, NRooms)
        ;   Result = failed(Reason), Retries = Used, NRooms = 0
        )
    ).

%! last_failure(-RoomId, -Reason)
%  solve_all/4 records the room that broke so the retry loop can see it.
:- dynamic last_failure/2.

solve_all(_, [], Acc, Assignments) :-
    reverse(Acc, Nested),
    append(Nested, Assignments).
solve_all(Session, [room_group(RoomId, Students) | Rest], Acc, Assignments) :-
    solve_room(Session, RoomId, Students, RoomResult),
    (   RoomResult = ok(RoomAssignments)
    ->  solve_all(Session, Rest, [RoomAssignments | Acc], Assignments)
    ;   RoomResult = failed(Reason),
        retractall(last_failure(_, _)),
        assertz(last_failure(RoomId, Reason)),
        fail
    ).


% ===========================================================================
% Pretty printing for the Prolog console
% ===========================================================================

%! print_result(+Result) is det.
print_result(ok(Assignments)) :- !,
    length(Assignments, N),
    format("ok: ~d assignment(s)~n", [N]),
    findall(R, member(assign(_, _, R, _, _), Assignments), Rooms),
    msort(Rooms, Sorted),
    clumped(Sorted, Counts),
    forall(member(Room-Count, Counts),
           format("  ~w: ~d student(s)~n", [Room, Count])),
    ( N =< 30 -> forall(member(A, Assignments), format("  ~q~n", [A])) ; true ).
print_result(failed(Reason)) :-
    format("failed: ~q~n", [Reason]).

%! print_room(+RoomId, +Assignments) is det.
%  ASCII seat grid for one room - the console twin of the web UI.
print_room(RoomId, Assignments) :-
    room_layout(RoomId, Rows, Cols, _Seats),
    format("~nRoom ~w  (~wx~w)~n", [RoomId, Rows, Cols]),
    forall(between(1, Rows, R),
           ( forall(between(1, Cols, C), print_cell(RoomId, R, C, Assignments)),
             nl )).

print_cell(RoomId, R, C, Assignments) :-
    (   memberchk(assign(S, _, RoomId, R, C), Assignments)
    ->  format("~w ", [S])
    ;   user:seat(RoomId, R, C, accessible)
    ->  format("~w ", ['[...] '])
    ;   format("~w ", ['.....'])
    ).


% ===========================================================================
% JSON helpers for the Python bridge (Member C)
% ===========================================================================
% The bridge can parse the raw ok/1 and failed/1 terms through pyswip, but
% going through JSON keeps large results fast and unambiguous.

%! generate_seating_json(+Session, +Filters, -Json) is det.
generate_seating_json(Session, Filters, Json) :-
    generate_seating(Session, Filters, Result, Stats),
    Stats = stats(NStudents, NRooms, Retries, Millis),
    result_dict(Result, Dict),
    atom_json_dict(Json,
        _{ result: Dict,
           stats: _{ students: NStudents, rooms: NRooms,
                     retries: Retries, millis: Millis } },
        [as(atom)]).

%! seating_report_json(+Session, +Filters, -Json) is det.
%  Generates AND validates in one call - this is what the web UI uses.
seating_report_json(Session, Filters, Json) :-
    generate_seating(Session, Filters, Result, Stats),
    Stats = stats(NStudents, NRooms, Retries, Millis),
    result_dict(Result, Dict),
    (   Result = ok(Assignments)
    ->  get_time(V0),
        validate_seating(Session, Filters, Assignments, Report),
        get_time(V1),
        VMillis is round((V1 - V0) * 1000),
        report_dict(Report, ReportDict0),
        ReportDict = ReportDict0.put(millis, VMillis)
    ;   ReportDict = _{ status: "not_run", violations: [], millis: 0 }
    ),
    atom_json_dict(Json,
        _{ result: Dict,
           validation: ReportDict,
           stats: _{ students: NStudents, rooms: NRooms,
                     retries: Retries, millis: Millis } },
        [as(atom)]).

result_dict(ok(Assignments), _{ status: "ok", assignments: List }) :- !,
    findall(_{ student: S, name: Name, major: Major, year: Year,
               exam: E, room: R, row: Row, col: Col,
               needs_accessible: NeedsAccessible },
            ( member(assign(S, E, R, Row, Col), Assignments),
              student_fields(S, Name, Major, Year),
              student_access_need(S, NeedsAccessible) ),
            List).
result_dict(failed(Reason), _{ status: "failed", reason: Text, detail: Detail }) :-
    term_string(Reason, Text),
    reason_detail(Reason, Detail).

student_access_need(StudentId, true) :-
    rules:needs_accessible(StudentId), !.
student_access_need(_, false).

student_fields(S, Name, Major, Year) :-
    (   student_display(S, Name0, Major0, Year0)
    ->  Name = Name0, Major = Major0, Year = Year0
    ;   Name = S, Major = unknown, Year = 0
    ).

reason_detail(not_enough_seats(Room, Needed, Have),
              _{ kind: "not_enough_seats", room: Room,
                 needed: Needed, have: Have }) :- !.
reason_detail(not_enough_accessible(Room, Needed, Have),
              _{ kind: "not_enough_accessible", room: Room,
                 needed: Needed, have: Have }) :- !.
reason_detail(no_solution(Room),
              _{ kind: "no_solution", room: Room }) :- !.
reason_detail(search_limit(Room),
              _{ kind: "search_limit", room: Room,
                 message: "Seating search reached its work limit; the room may still be feasible." }) :- !.
reason_detail(search_error(Room),
              _{ kind: "search_error", room: Room,
                 message: "Seating search failed unexpectedly." }) :- !.
reason_detail(_, _{ kind: "other" }).

report_dict(valid, _{ status: "valid", violations: [] }) :- !.
report_dict(invalid(Violations), _{ status: "invalid", violations: List }) :-
    findall(_{ rule: Rule, details: Term, message: Msg },
            ( member(violation(Rule, Details), Violations),
              term_string(Details, Term),
              explain_violation(violation(Rule, Details), Msg) ),
            List).

%! catalogue_json(-Json) is det.
%  Everything the UI needs to build its pickers.
catalogue_json(Json) :-
    list_sessions(Sessions),
    list_majors(Majors),
    list_years(Years),
    findall(_{ id: S, date: D, start: St, end: En, exams: Exams,
               students: N },
            ( member(S, Sessions),
              session_info(S, D, St, En),
              exams_in_session(S, Exams),
              selection_size(S, filters([], []), N, _) ),
            SessionDicts),
    findall(_{ id: R, rows: Rows, cols: Cols, available: Avail },
            user:room(R, Rows, Cols, Avail),
            RoomDicts),
    dataset_summary(dataset(NS, NSub, NSess, NRooms, NSeats)),
    atom_json_dict(Json,
        _{ sessions: SessionDicts, majors: Majors, years: Years,
           rooms: RoomDicts,
           summary: _{ students: NS, subjects: NSub, sessions: NSess,
                       rooms_available: NRooms, seats: NSeats } },
        [as(atom)]).

%! dataset_json(-Json) is det.
%  Everything in the loaded data file, for the UI's data page: students
%  (with the exams each one sits), subjects (with their session and the
%  cohorts that take them), sessions and rooms. No seating is done here.
dataset_json(Json) :-
    list_majors(Majors),
    list_years(Years),
    findall(_{ id: Id, name: Name, major: M, year: Y, access: A, exams: Exams },
            ( user:student(Id, M, Y, A),
              ( user:student_name(Id, Name) -> true ; Name = '' ),
              findall(C, user:enrolled(Id, C), Exams0),
              msort(Exams0, Exams) ),
            Students),
    findall(_{ code: C, session: S, students: N, cohorts: Cohorts },
            ( user:subject(C),
              ( user:exam(C, S0) -> S = S0 ; S = '' ),
              aggregate_all(count, user:enrolled(_, C), N),
              (   setof(M-Y, St^A^( user:enrolled(St, C),
                                    user:student(St, M, Y, A) ), Pairs)
              ->  true
              ;   Pairs = []
              ),
              findall(_{ major: M, year: Y }, member(M-Y, Pairs), Cohorts) ),
            Subjects),
    list_sessions(SessionIds),
    findall(_{ id: S, date: D, start: St, end: En },
            ( member(S, SessionIds), session_info(S, D, St, En) ),
            Sessions),
    findall(_{ id: R, rows: Rows, cols: Cols, available: Avail,
               seats: NSeats, accessible: NAcc, accessible_at: AccAt },
            ( user:room(R, Rows, Cols, Avail),
              aggregate_all(count, user:seat(R, _, _, _), NSeats),
              findall([Row, Col], user:seat(R, Row, Col, accessible), AccAt),
              length(AccAt, NAcc) ),
            Rooms),
    total_capacity(Seats, AccSeats),
    atom_json_dict(Json,
        _{ majors: Majors, years: Years, students: Students,
           subjects: Subjects, sessions: Sessions, rooms: Rooms,
           seats: Seats, accessible_seats: AccSeats },
        [as(atom)]).

%! room_layout_json(+RoomId, -Json) is det.
room_layout_json(RoomId, Json) :-
    room_layout(RoomId, Rows, Cols, Seats),
    findall(_{ row: R, col: C, type: T },
            member(seat(R, C, T), Seats), SeatDicts),
    atom_json_dict(Json,
        _{ room: RoomId, rows: Rows, cols: Cols, seats: SeatDicts },
        [as(atom)]).



% ===========================================================================
% Session capacity: who sits a session, per cohort           (for the UI)
% ===========================================================================

%! session_cohorts(+Session, -Cohorts) is det.
%  Cohorts = [cohort(Major, Year, Students, Accessible, Exams), ...]
%  for everyone with an exam in Session. The UI sums these to show
%  "selected N / seats" and to refuse a selection that cannot fit.
session_cohorts(Session, Cohorts) :-
    students_in_session(Session, filters([], []), Students),
    findall((M-Y)-row(St, C),
            ( member(s(St, C), Students), user:student(St, M, Y, _) ),
            Rows0),
    keysort(Rows0, Rows),
    group_pairs_by_key(Rows, Groups),
    findall(cohort(M, Y, N, NA, Exams),
            ( member((M-Y)-Members, Groups),
              length(Members, N),
              aggregate_all(count,
                            ( member(row(St, _), Members),
                              needs_accessible(St) ),
                            NA),
              findall(C, member(row(_, C), Members), Cs),
              sort(Cs, Exams) ),
            Cohorts).

%! selection_size(+Session, +Filters, -Students, -Accessible) is det.
selection_size(Session, Filters, N, NA) :-
    students_in_session(Session, Filters, Students),
    length(Students, N),
    aggregate_all(count,
                  ( member(s(St, _), Students), needs_accessible(St) ),
                  NA).

%! session_cohorts_json(+Session, -Json) is det.
session_cohorts_json(Session, Json) :-
    session_cohorts(Session, Cohorts),
    total_capacity(Seats, ASeats),
    findall(_{ major: M, year: Y, students: N, accessible: NA, exams: Ex },
            member(cohort(M, Y, N, NA, Ex), Cohorts),
            Dicts),
    atom_json_dict(Json,
        _{ session: Session, seats: Seats, accessible_seats: ASeats,
           cohorts: Dicts },
        [as(atom)]).


% ===========================================================================
% Whole-term run: seat every session, report per cohort      (B)
% ===========================================================================

%! seat_term(-SessionReports, -Coverage) is det.
%
%  Runs generate_seating/4 + validate_seating/4 for every session.
%
%  SessionReports = [term_session(Session, Status, Students, Rooms, Millis)]
%      Status = ok | invalid(NViolations) | failed(Reason)
%  Coverage       = [cohort(Major, Year, SeatedExams, TotalExams), ...]
%      a cohort is done when SeatedExams == TotalExams. Exams count once per
%      student per subject, so a cohort of 50 with 5 subjects has 250.
seat_term(Reports, Coverage) :-
    list_sessions(Sessions),
    findall(R-Seated,
            ( member(S, Sessions), seat_one_session(S, R, Seated) ),
            Pairs),
    pairs_keys_values(Pairs, Reports, SeatedLists),
    append(SeatedLists, Seated),
    cohort_coverage(Seated, Coverage).

seat_one_session(S, term_session(S, Status, N, Rooms, Ms), Seated) :-
    generate_seating(S, filters([], []), Result, stats(N, Rooms, _, Ms)),
    (   Result = ok(As)
    ->  validate_seating(S, filters([], []), As, Report),
        (   Report == valid
        ->  Status = ok,
            findall(St, member(assign(St, _, _, _, _), As), Seated)
        ;   Report = invalid(Vs), length(Vs, NV),
            Status = invalid(NV), Seated = []
        )
    ;   Result = failed(Reason), Status = failed(Reason), Seated = []
    ).

cohort_coverage(Seated, Coverage) :-
    findall(M-Y,
            ( user:enrolled(St, C), user:exam(C, _), user:student(St, M, Y, _) ),
            TotalKeys0),
    msort(TotalKeys0, TotalKeys),
    clumped(TotalKeys, Totals),
    findall(M-Y, ( member(St, Seated), user:student(St, M, Y, _) ), SeatKeys0),
    msort(SeatKeys0, SeatKeys),
    clumped(SeatKeys, SeatCounts),
    findall(cohort(M, Y, Done, Total),
            ( member((M-Y)-Total, Totals),
              ( memberchk((M-Y)-Done, SeatCounts) -> true ; Done = 0 ) ),
            Coverage).

%! term_report_json(-Json) is det.
term_report_json(Json) :-
    get_time(T0),
    seat_term(Reports, Coverage),
    get_time(T1),
    Millis is round((T1 - T0) * 1000),
    findall(D, ( member(R, Reports), term_session_dict(R, D) ), SDicts),
    findall(_{ major: M, year: Y, seated: Done, total: Total },
            member(cohort(M, Y, Done, Total), Coverage),
            CDicts),
    atom_json_dict(Json,
        _{ sessions: SDicts, coverage: CDicts, millis: Millis },
        [as(atom)]).

term_session_dict(term_session(S, Status, N, Rooms, Ms), Dict) :-
    session_info(S, Date, Start, End),
    exams_in_session(S, Exams),
    length(Exams, NExams),
    Base = _{ session: S, date: Date, start: Start, end: End,
              exams: NExams, students: N, rooms: Rooms, millis: Ms },
    (   Status == ok
    ->  Dict = Base.put(_{ status: "ok" })
    ;   Status = invalid(NV)
    ->  Dict = Base.put(_{ status: "invalid", violations: NV })
    ;   Status = failed(Reason),
        term_string(Reason, Text),
        Dict = Base.put(_{ status: "failed", reason: Text })
    ).

%! print_term_report is det.
%  Console version: the session table and the year x major coverage grid.
print_term_report :-
    seat_term(Reports, Coverage),
    format("~nWhole term~n~`-t~60|~n"),
    forall(member(term_session(S, Status, N, Rooms, Ms), Reports),
           format("~w~t~10| ~d students~t~26| ~d rooms~t~36| ~q (~d ms)~n",
                  [S, N, Rooms, Status, Ms])),
    findall(M, member(cohort(M, _, _, _), Coverage), Ms0), sort(Ms0, Majors),
    findall(Y, member(cohort(_, Y, _, _), Coverage), Ys0), sort(Ys0, Years),
    format("~nExams seated per cohort (seated/total, ! = not finished)~n"),
    findall(H, ( member(Y, Years), format(atom(H), "year ~d", [Y]) ), Heads),
    print_cells(major, Heads),
    forall(member(M, Majors),
           ( findall(Cell,
                     ( member(Y, Years),
                       (   memberchk(cohort(M, Y, D, T), Coverage)
                       ->  ( D == T -> Mark = '' ; Mark = ' !' ),
                           format(atom(Cell), "~d/~d~w", [D, T, Mark])
                       ;   Cell = '-'
                       ) ),
                     Cells),
             upcase_atom(M, Label),
             print_cells(Label, Cells) )),
    aggregate_all(sum(D), member(cohort(_, _, D, _), Coverage), AllD),
    aggregate_all(sum(T), member(cohort(_, _, _, T), Coverage), AllT),
    format("~ntotal: ~d / ~d exam seats~n", [AllD, AllT]).

print_cells(First, Cells) :-
    format(atom(A), "~w~t~8|", [First]), write(A),
    forall(member(C, Cells),
           ( format(atom(P), "~w~t~12|", [C]), write(P) )),
    nl.


% ===========================================================================
% Constraints as data: evaluate the whole term under the active constraints
% ===========================================================================

%! evaluate(-Report) is det.
%
%  1. rebuild the timetable with the active constraints (constraints.pl)
%     and install it as the exam/2 facts,
%  2. seat every session,
%  3. re-check every hard rule independently (validator + timetable rules),
%  4. score the soft rules: penalty = weight x number of violations.
%
%  Report = report(Feasible, Problems, TimetableStats, Sessions, Rooms,
%                  Soft, Score, Millis)
evaluate(Report) :-
    get_time(T0),
    build_timetable([], TT),
    (   TT = failed(Reason)
    ->  explain_timetable_failure(Reason, Why),
        Problems = [problem(timetable, Reason, Why)],
        TTStats = none, Sessions = [], Rooms = rooms(0, 0, []),
        Soft = [], Score = 0
    ;   TT = ok(Timetable, TTStats),
        install_timetable(Timetable),
        list_sessions(SessionIds),
        findall(Sess, ( member(S, SessionIds), evaluate_session(S, Sess) ), Sessions),
        session_problems(Sessions, SessionProblems),
        timetable_problems(TimetableProblems),
        append(SessionProblems, TimetableProblems, Problems),
        room_usage(Sessions, Rooms),
        soft_scores(Sessions, Soft),
        aggregate_all(sum(P), member(soft(_, _, _, _, P, _), Soft), Score)
    ),
    ( Problems == [] -> Feasible = true ; Feasible = false ),
    get_time(T1),
    Millis is round((T1 - T0) * 1000),
    Report = report(Feasible, Problems, TTStats, Sessions, Rooms, Soft, Score, Millis),
    !.

%! install_timetable(+Timetable) is det.
%  Timetable = [Subject-Session, ...] replaces the exam/2 facts.
install_timetable(Timetable) :-
    retractall(user:exam(_, _)),
    forall(member(C-S, Timetable), assertz(user:exam(C, S))),
    allocation:forget_allocations.

evaluate_session(S, sess(S, Status, N, RoomsUsed, Retries, Ms, As)) :-
    generate_seating(S, filters([], []), Result, stats(N, _, Retries, Ms)),
    (   Result = ok(As)
    ->  validate_seating(S, filters([], []), As, Report),
        ( Report == valid -> Status = ok ; Status = Report ),
        findall(R, member(assign(_, _, R, _, _), As), Rs0), sort(Rs0, RoomsUsed)
    ;   Result = failed(Reason), Status = failed(Reason), As = [], RoomsUsed = []
    ).

session_problems(Sessions, Problems) :-
    findall(problem(session(S), Status, Why),
            ( member(sess(S, Status, _, _, _, _, _), Sessions),
              Status \== ok,
              status_text(Status, Why) ),
            Problems).

status_text(failed(Reason), Why) :- !,
    format(atom(Why), 'no seating found: ~q', [Reason]).
status_text(invalid(Vs), Why) :-
    findall(T, ( member(V, Vs), explain_violation(V, T) ), Ts0),
    length(Ts0, N),
    ( length(Ts, 3), append(Ts, _, Ts0) -> true ; Ts = Ts0 ),
    atomic_list_concat(Ts, '; ', Joined),
    format(atom(Why), '~d violation(s): ~w', [N, Joined]).

% The timetabler enforces the hard timetable rules; check them again on the
% installed timetable, independently of how it was built.
timetable_problems(Problems) :-
    findall(problem(timetable, C, Why),
            ( active(_, C, hard),
              constraint_level(C, Level), memberchk(Level, [timetable]),
              timetable_violations(C, Ws), Ws = [W | _],
              length(Ws, N),
              explain_witness(C, W, First),
              format(atom(Why), '~q broken ~d time(s), e.g. ~w', [C, N, First]) ),
            Problems0),
    findall(problem(timetable, exam_clash, Why),
            ( exam_clash(St, S), format(atom(Why), '~w has two exams in ~w', [St, S]) ),
            Clashes),
    append(Problems0, Clashes, Problems).

%! room_usage(+Sessions, -Rooms) is det.
%  Rooms = rooms(PeakRooms, DistinctRooms, BySize)
%  BySize = [size(Rows, Cols, Seats, MostAtOnce, Available), ...]: for each
%  room size, the most rooms of that size open in any one session - the
%  rooms this exam period actually needs.
room_usage(Sessions, rooms(Peak, Distinct, BySize)) :-
    findall(L, ( member(sess(_, _, _, Rs, _, _, _), Sessions), length(Rs, L) ), Ls),
    max_list([0 | Ls], Peak),
    findall(R, ( member(sess(_, _, _, Rs, _, _, _), Sessions), member(R, Rs) ), All0),
    sort(All0, All), length(All, Distinct),
    findall(Rows-Cols, user:room(_, Rows, Cols, _), Sizes0), sort(Sizes0, Sizes),
    findall(size(Rows, Cols, Seats, Most, Avail),
            ( member(Rows-Cols, Sizes),
              Seats is Rows * Cols,
              findall(K, ( member(sess(_, _, _, Rs, _, _, _), Sessions),
                           aggregate_all(count, ( member(R, Rs),
                                                  user:room(R, Rows, Cols, _) ), K) ),
                      Ks),
              max_list([0 | Ks], Most),
              aggregate_all(count, ( user:room(R, Rows, Cols, _),
                                     rules:available_room(R, _, _) ), Avail) ),
            BySize).

%! soft_scores(+Sessions, -Soft) is det.
%  Soft = [soft(Id, Constraint, Weight, Units, Penalty, Examples), ...]
soft_scores(Sessions, Soft) :-
    findall(soft(Id, C, W, Units, Penalty, Examples),
            ( active(Id, C, soft(W)),
              soft_witnesses(C, Sessions, Ws),
              aggregate_all(sum(U), ( member(Wt, Ws), units(C, Wt, U) ), Units),
              Penalty is W * Units,
              ( length(Ex, 3), append(Ex, _, Ws) -> true ; Ex = Ws ),
              findall(T, ( member(Wt, Ex), explain_witness(C, Wt, T) ), Examples) ),
            Soft).

soft_witnesses(C, Sessions, Ws) :-
    constraint_level(C, Level),
    (   Level == timetable
    ->  timetable_violations(C, Ws)
    ;   findall(W, ( member(sess(_, _, _, _, _, _, As), Sessions),
                     seat_violations(C, As, SWs), member(W, SWs) ), Ws)
    ).

%  How many violations a witness counts for.
units(max_exams_per_day(K), too_many(_, _, N), U) :- !, U is N - K.
units(cohort_together, split(_, Rooms), U) :- !, length(Rooms, L), U is L - 1.
units(_, _, 1).


% ---------------------------------------------------------------------------
% "Why is it impossible?" - relax one hard constraint at a time
% ---------------------------------------------------------------------------

%! why_infeasible(-Findings) is det.
%  For every active hard constraint: would the term be feasible without it?
%  Findings = [relax(Id, Constraint, Feasible, Score), ...]
%  The constraint set and the timetable are restored afterwards.
why_infeasible(Findings) :-
    findall(C-S, user:exam(C, S), Saved),
    findall(relax(Id, C, Feasible, Score),
            ( active(Id, C, hard),
              setup_call_cleanup(
                  retract(active(Id, C, hard)),
                  ( evaluate(report(Feasible, _, _, _, _, _, Score, _)) ),
                  assertz(active(Id, C, hard))) ),
            Findings),
    install_timetable(Saved).


% ---------------------------------------------------------------------------
% JSON for the UI
% ---------------------------------------------------------------------------

%! constraints_json(-Json) is det.
constraints_json(Json) :-
    findall(_{ id: Id, term: T, name: Name, level: Level, strength: Kind,
               weight: W, text: Text, rule: Rule },
            ( active(Id, C, Strength),
              term_text(C, T),
              constraint_name(C, Name),
              constraint_level(C, Level),
              strength_parts(Strength, Kind, W),
              describe(C, Text),
              ( C = custom(_, _, R0) -> atom_string(R0, Rule) ; Rule = "" ) ),
            Active0),
    sort(id, @<, Active0, Active),
    findall(_{ name: N, text: Text }, core_rule(N, Text), Core),
    findall(_{ name: N, template: TT, level: L, params: Ps, strengths: Ss, text: Text },
            ( catalog_entry(N, T, L, Params, Ss, Text),
              template_text(T, Params, TT),
              findall(_{ name: PN, type: PT }, member(PN:PT, Params), Ps) ),
            Catalog),
    findall(_{ level: L, head: H, text: Text },
            ( vocabulary(L, Head, Text), term_text(Head, H) ),
            Vocab),
    atom_json_dict(Json,
        _{ active: Active, core: Core, catalog: Catalog, vocabulary: Vocab },
        [as(atom)]).

constraint_name(custom(_, Name, _), Name) :- !.
constraint_name(C, Name) :- functor(C, Name, _).

strength_parts(hard, hard, 0).
strength_parts(soft(W), soft, W).

term_text(T, Text) :- format(atom(Text), '~q', [T]).

template_text(T, Params, Text) :-
    T =.. [N | _],
    (   Params == []
    ->  Text = N
    ;   findall(P, member(P:_, Params), Names),
        atomic_list_concat(Names, ', ', Args),
        format(atom(Text), '~w(~w)', [N, Args])
    ).

%! add_constraint_json(+Text, +Strength, -Json) is det.
%  Text is a constraint term as typed in the UI, e.g. 'column_gap(1)'.
add_constraint_json(Text, Strength, Json) :-
    catch(( term_string(C, Text),
            (   ground(C) -> true
            ;   throw(error(constraint('Fill in every parameter, e.g. separation(2).'), _))
            ),
            add_constraint(C, Strength, Id),
            Out = _{ ok: true, id: Id } ),
          E, error_json(E, Out)),
    atom_json_dict(Json, Out, [as(atom)]).

%! add_custom_json(+Level, +Name, +RuleText, +Strength, -Json) is det.
add_custom_json(Level, Name, RuleText, Strength, Json) :-
    catch(( add_constraint(custom(Level, Name, RuleText), Strength, Id),
            Out = _{ ok: true, id: Id } ),
          E, error_json(E, Out)),
    atom_json_dict(Json, Out, [as(atom)]).

error_json(error(constraint(Msg), _), _{ ok: false, message: Msg }) :- !.
error_json(error(syntax_error(S), _), _{ ok: false, message: M }) :- !,
    format(atom(M), 'Not a valid Prolog term (~w).', [S]).
error_json(E, _{ ok: false, message: M }) :-
    message_to_codes(E, M).

message_to_codes(E, M) :-
    catch(message_to_codes(E, _, Codes), _, fail), !,
    atom_codes(M, Codes).
message_to_codes(E, M) :-
    format(atom(M), '~q', [E]).

%! evaluate_json(-Json) is det.
evaluate_json(Json) :-
    evaluate(Report),
    eval_report_dict(Report, Dict),
    atom_json_dict(Json, Dict, [as(atom)]).

eval_report_dict(report(Feasible, Problems, TTStats, Sessions, rooms(Peak, Distinct, BySize),
                   Soft, Score, Millis), Dict) :-
    findall(_{ where: Where, text: Why },
            ( member(problem(W0, _, Why), Problems), term_text(W0, Where) ),
            ProblemDicts),
    (   TTStats = stats(SameDay, PeakLoad, Limit, NSlots)
    ->  TT = _{ same_day_pairs: SameDay, peak: PeakLoad, limit: Limit, sessions: NSlots }
    ;   TT = null
    ),
    findall(_{ session: S, date: D, start: St, status: StatusText, ok: Ok,
               students: N, rooms: NR, retries: Re, millis: Ms },
            ( member(sess(S, Status, N, Rs, Re, Ms, _), Sessions),
              session_info(S, D, St, _),
              length(Rs, NR),
              ( Status == ok -> Ok = true, StatusText = ok
              ; Ok = false, status_text(Status, StatusText) ) ),
            SessionDicts),
    findall(_{ rows: R, cols: C, seats: Seats, needed: Most, available: Avail },
            member(size(R, C, Seats, Most, Avail), BySize),
            SizeDicts),
    findall(_{ id: Id, term: T, weight: W, count: U, penalty: P, examples: Ex,
               text: Text },
            ( member(soft(Id, C, W, U, P, Ex), Soft),
              term_text(C, T), describe(C, Text) ),
            SoftDicts),
    Dict = _{ feasible: Feasible, problems: ProblemDicts, timetable: TT,
              sessions: SessionDicts,
              rooms: _{ peak: Peak, distinct: Distinct, by_size: SizeDicts },
              soft: SoftDicts, score: Score, millis: Millis }.

%! plan_option_json(+Option, +Weights, -Json) is det.
%  One planner option (planner.pl), as JSON for the Planner page.
plan_option_json(Option, Weights, Json) :-
    plan_option(Option, Weights,
                result(Feasible, Why, RoomsNeeded, BySize, Penalty, Score, Report)),
    Option = option(Days, Slots, _, _),
    Weights = weights(DayCost, RoomCost),
    length(Slots, NSlots),
    Report = report(_, _, TT, _, rooms(Peak, _, _), Soft, _, Millis),
    (   TT = stats(_, PeakLoad, Limit, NSessions)
    ->  true
    ;   PeakLoad = 0, Limit = 0, NSessions is Days * NSlots
    ),
    findall(_{ rows: R, cols: C, seats: S, needed: N, available: A },
            member(size(R, C, S, N, A), BySize), Sizes),
    findall(_{ term: T, penalty: P },
            ( member(soft(_, Con, _, _, P, _), Soft), term_text(Con, T) ), SoftDicts),
    ( Score == none -> ScoreOut = null ; ScoreOut = Score ),
    DayPart is Days * DayCost,
    RoomPart is RoomsNeeded * RoomCost,
    atom_json_dict(Json,
        _{ days: Days, slots: NSlots, sessions: NSessions, feasible: Feasible,
           why: Why, rooms_needed: RoomsNeeded, rooms_peak: Peak, by_size: Sizes,
           penalty: Penalty, soft: SoftDicts, day_cost: DayPart, room_cost: RoomPart,
           score: ScoreOut, peak_load: PeakLoad, limit: Limit, millis: Millis },
        [as(atom)]).

%! why_infeasible_json(-Json) is det.
why_infeasible_json(Json) :-
    why_infeasible(Findings),
    findall(_{ id: Id, term: T, text: Text, feasible: F, score: S },
            ( member(relax(Id, C, F, S), Findings),
              term_text(C, T), describe(C, Text) ),
            Dicts),
    atom_json_dict(Json, _{ relaxations: Dicts }, [as(atom)]).
