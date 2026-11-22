% ===========================================================================
% validator.pl  -  independent check of a finished seating plan
% ===========================================================================
% The validator deliberately does NOT reuse the solver's bookkeeping. It
% re-derives everything from the raw facts, so a bug in allocation.pl or
% solver.pl shows up here instead of being silently agreed with.
%
%   validate_seating(+Session, +Filters, +Assignments, -Report)
%   Report = valid | invalid([violation(Rule, Details), ...])
%
% Rule is one of (README.md section 8.4):
%   one_seat_per_student, seat_unique, room_capacity, room_available,
%   accessibility, exam_clash, separation, missing_student
% or the term of any other ACTIVE HARD constraint from constraints.pl that
% the plan breaks, e.g. violation(column_gap(1), same_column(...)).
% ===========================================================================

:- module(validator, [
        validate_seating/4,
        explain_violation/2
   ]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(rules).
:- use_module(allocation).
:- use_module(constraints, []).


%! validate_seating(+Session, +Filters, +Assignments, -Report) is det.
validate_seating(Session, Filters, Assignments, Report) :-
    findall(V, violation_of(Session, Filters, Assignments, V), Violations0),
    sort(Violations0, Violations),
    ( Violations == [] -> Report = valid ; Report = invalid(Violations) ).

violation_of(Session, Filters, Assignments, V) :-
    (   check_one_seat_per_student(Assignments, V)
    ;   check_seat_unique(Assignments, V)
    ;   check_seat_exists(Assignments, V)
    ;   check_room_available(Assignments, V)
    ;   check_room_capacity(Assignments, V)
    ;   check_accessibility(Assignments, V)
    ;   check_separation(Assignments, V)
    ;   check_exam_clash(Session, Assignments, V)
    ;   check_missing_student(Session, Filters, Assignments, V)
    ;   check_right_exam(Session, Assignments, V)
    ;   check_active_constraints(Assignments, V)
    ).


% ---------------------------------------------------------------------------
% every other active hard constraint (constraints.pl)
%   separation and accessibility have their own checks above; closed rooms
%   are caught by room_available.
% ---------------------------------------------------------------------------
check_active_constraints(Assignments, violation(C, W)) :-
    constraints:active(_, C, hard),
    constraints:constraint_level(C, Level),
    memberchk(Level, [seat, room]),
    \+ memberchk(C, [accessible_seats]),
    C \= separation(_),
    C \= room_closed(_),
    constraints:seat_violations(C, Assignments, Ws),
    member(W, Ws).


% ---------------------------------------------------------------------------
% one_seat_per_student
%   A student must appear exactly once per exam in the plan.
% ---------------------------------------------------------------------------
check_one_seat_per_student(Assignments, violation(one_seat_per_student, D)) :-
    findall(S-E, member(assign(S, E, _, _, _), Assignments), Pairs),
    msort(Pairs, Sorted),
    clumped(Sorted, Counts),
    member((S-E)-N, Counts),
    N > 1,
    D = student_seated_twice(S, E, N).


% ---------------------------------------------------------------------------
% seat_unique
%   No physical seat may hold two students.
% ---------------------------------------------------------------------------
check_seat_unique(Assignments, violation(seat_unique, D)) :-
    findall(seat(R, Row, Col),
            member(assign(_, _, R, Row, Col), Assignments), Seats),
    msort(Seats, Sorted),
    clumped(Sorted, Counts),
    member(seat(R, Row, Col)-N, Counts),
    N > 1,
    findall(S, member(assign(S, _, R, Row, Col), Assignments), Students),
    D = seat_shared(R, Row, Col, Students).


% ---------------------------------------------------------------------------
% room_capacity (part 1): the seat must actually exist in that room
% ---------------------------------------------------------------------------
check_seat_exists(Assignments, violation(room_capacity, D)) :-
    member(assign(S, _, RoomId, Row, Col), Assignments),
    \+ user:seat(RoomId, Row, Col, _),
    D = seat_does_not_exist(S, RoomId, Row, Col).


% ---------------------------------------------------------------------------
% room_available
% ---------------------------------------------------------------------------
check_room_available(Assignments, violation(room_available, D)) :-
    findall(R, member(assign(_, _, R, _, _), Assignments), Rooms),
    sort(Rooms, Used),
    member(RoomId, Used),
    \+ rules:available_room(RoomId, _, _),
    (   constraints:room_closed(RoomId)
    ->  D = room_closed_by_constraint(RoomId)
    ;   user:room(RoomId, _, _, Avail)
    ->  D = room_not_available(RoomId, Avail)
    ;   D = room_unknown(RoomId)
    ).


% ---------------------------------------------------------------------------
% room_capacity (part 2): headcount vs seats
% ---------------------------------------------------------------------------
check_room_capacity(Assignments, violation(room_capacity, D)) :-
    findall(R, member(assign(_, _, R, _, _), Assignments), Rooms),
    msort(Rooms, Sorted),
    clumped(Sorted, Counts),
    member(RoomId-N, Counts),
    aggregate_all(count, user:seat(RoomId, _, _, _), Capacity),
    N > Capacity,
    D = over_capacity(RoomId, N, Capacity).


% ---------------------------------------------------------------------------
% accessibility
% ---------------------------------------------------------------------------
check_accessibility(Assignments, violation(accessibility, D)) :-
    member(assign(S, _, RoomId, Row, Col), Assignments),
    rules:requires_accessible_seat(S),
    user:seat(RoomId, Row, Col, Type),
    Type \== accessible,
    user:student(S, _, _, Access),
    D = needs_accessible_seat(S, Access, RoomId, Row, Col, Type).


% ---------------------------------------------------------------------------
% separation
%   Two students of the same exam in the same room and row must be at least
%   min_separation + 1 columns apart.
% ---------------------------------------------------------------------------
check_separation(Assignments, violation(separation, D)) :-
    rules:min_separation(Sep),
    Need is Sep + 1,
    member(assign(S1, Exam, RoomId, Row, Col1), Assignments),
    member(assign(S2, Exam, RoomId, Row, Col2), Assignments),
    S1 @< S2,
    Dist is abs(Col1 - Col2),
    Dist < Need,
    D = too_close(S1, S2, Exam, RoomId, Row, Col1, Col2, Dist, Need).


% ---------------------------------------------------------------------------
% exam_clash
%   Nobody may be seated for two different exams of the same session.
% ---------------------------------------------------------------------------
check_exam_clash(_Session, Assignments, violation(exam_clash, D)) :-
    member(assign(S, E1, _, _, _), Assignments),
    member(assign(S, E2, _, _, _), Assignments),
    E1 @< E2,
    D = two_exams_same_session(S, E1, E2).


% ---------------------------------------------------------------------------
% missing_student
%   Everyone who should sit this session must appear in the plan.
% ---------------------------------------------------------------------------
check_missing_student(Session, Filters, Assignments,
                      violation(missing_student, D)) :-
    allocation:students_in_session(Session, Filters, Expected),
    findall(s(S, E), member(assign(S, E, _, _, _), Assignments), Got0),
    sort(Got0, Got),
    member(s(S, E), Expected),
    \+ memberchk(s(S, E), Got),
    D = not_seated(S, E).


% ---------------------------------------------------------------------------
% missing_student (reverse direction): somebody seated who should not be
% ---------------------------------------------------------------------------
check_right_exam(Session, Assignments, violation(missing_student, D)) :-
    member(assign(S, E, _, _, _), Assignments),
    (   \+ user:exam(E, Session)
    ->  D = wrong_session(S, E, Session)
    ;   \+ user:enrolled(S, E),
        D = not_enrolled(S, E)
    ).


% ---------------------------------------------------------------------------
% Human-readable messages for the UI
% ---------------------------------------------------------------------------

%! explain_violation(+Violation, -Text) is det.
explain_violation(violation(one_seat_per_student,
                            student_seated_twice(S, E, N)), Text) :- !,
    format(atom(Text), "~w has ~d seats for exam ~w (must be exactly 1)",
           [S, N, E]).
explain_violation(violation(seat_unique,
                            seat_shared(R, Row, Col, Students)), Text) :- !,
    format(atom(Text), "seat ~w R~wC~w is given to ~w",
           [R, Row, Col, Students]).
explain_violation(violation(room_capacity,
                            over_capacity(R, N, Cap)), Text) :- !,
    format(atom(Text), "room ~w holds ~d students but has only ~d seats",
           [R, N, Cap]).
explain_violation(violation(room_capacity,
                            seat_does_not_exist(S, R, Row, Col)), Text) :- !,
    format(atom(Text), "~w placed at ~w R~wC~w which does not exist",
           [S, R, Row, Col]).
explain_violation(violation(room_available,
                            room_not_available(R, A)), Text) :- !,
    format(atom(Text), "room ~w is used but its availability is '~w'", [R, A]).
explain_violation(violation(accessibility,
                            needs_accessible_seat(S, Acc, R, Row, Col, T)),
                  Text) :- !,
    format(atom(Text),
           "~w needs '~w' access but got a ~w seat at ~w R~wC~w",
           [S, Acc, T, R, Row, Col]).
explain_violation(violation(separation,
                            too_close(S1, S2, E, R, Row, C1, C2, D, Need)),
                  Text) :- !,
    format(atom(Text),
           "~w and ~w both sit ~w in ~w row ~w at columns ~w and ~w (distance ~d, need ~d)",
           [S1, S2, E, R, Row, C1, C2, D, Need]).
explain_violation(violation(exam_clash,
                            two_exams_same_session(S, E1, E2)), Text) :- !,
    format(atom(Text), "~w is seated for both ~w and ~w in one session",
           [S, E1, E2]).
explain_violation(violation(missing_student, not_seated(S, E)), Text) :- !,
    format(atom(Text), "~w sits ~w this session but has no seat", [S, E]).
explain_violation(violation(missing_student, not_enrolled(S, E)), Text) :- !,
    format(atom(Text), "~w is seated for ~w but is not enrolled in it", [S, E]).
explain_violation(violation(missing_student,
                            wrong_session(S, E, Sess)), Text) :- !,
    format(atom(Text), "~w is seated for ~w which is not in session ~w",
           [S, E, Sess]).
explain_violation(violation(room_available,
                            room_closed_by_constraint(R)), Text) :- !,
    format(atom(Text), "room ~w is used but a room_closed constraint closes it", [R]).
explain_violation(violation(Rule, Details), Text) :-
    \+ atom(Rule), !,                       % an active constraint term
    constraints:explain_witness(Rule, Details, Why),
    format(atom(Text), "~w (~q)", [Why, Rule]).
explain_violation(violation(Rule, Details), Text) :-
    format(atom(Text), "~w: ~q", [Rule, Details]).
