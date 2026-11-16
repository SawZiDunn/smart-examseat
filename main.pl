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

:- initialization(load_dataset).


% ===========================================================================
% Dataset loading
% ===========================================================================

load_dataset :-
    (   getenv('SMARTEXAMSEAT_DATA', File)
    ->  true
    ;   File = 'data.pl'
    ),
    load_data_file(File).

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
% generate_seating/3  (CONTRACT.md section 5.2)
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
               exam: E, room: R, row: Row, col: Col },
            ( member(assign(S, E, R, Row, Col), Assignments),
              student_fields(S, Name, Major, Year) ),
            List).
result_dict(failed(Reason), _{ status: "failed", reason: Text, detail: Detail }) :-
    term_string(Reason, Text),
    reason_detail(Reason, Detail).

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
