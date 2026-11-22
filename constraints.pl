% ===========================================================================
% constraints.pl  -  the constraints, as data
% ===========================================================================
% Every rule the timetabler, the allocator, the seat solver and the validator
% obey (apart from the few that define what a seating plan IS) is a fact in
% this knowledge base:
%
%     active(Id, Constraint, Strength).       Strength = hard | soft(Weight)
%
%     active(1, separation(1),        hard).      % in the default set
%     active(2, accessible_seats,     hard).
%     active(3, session_fill(80),     hard).
%     active(4, max_exams_per_day(1), soft(10)).
%
% Adding or removing a constraint is assertz/retract. The solvers ask this
% module what is active, so the same search code obeys whatever rules are
% here - including rules the admin writes in Prolog (custom/3, checked by
% custom_rules.pl).
%
%   hard     the plan is only valid if it holds; the search prunes on it
%   soft(W)  may be broken; every violation adds W to the plan's penalty,
%            and the search prefers values that break it less
% ===========================================================================

:- module(constraints, [
        active/3,                   % ?Id, ?Constraint, ?Strength
        add_constraint/3,           % +Constraint, +Strength, -Id
        remove_constraint/1,        % +Id
        set_strength/2,             % +Id, +Strength
        reset_constraints/0,        % back to the default set
        clear_constraints/0,        % no optional constraints at all
        catalog_entry/6,            % ?Name, ?Template, ?Level, ?Params, ?Strengths, ?Text
        core_rule/2,                % ?Name, ?Text
        constraint_level/2,         % +Constraint, -Level
        describe/2,                 % +Constraint, -Text
        hard_separation/1,
        accessible_rule/1,
        room_closed/1,
        room_fill_percent/1,
        session_fill_percent/1,
        blocked_session/1,
        fixed_session/2,
        student_day_rules/2,        % -HardRules, -SoftRules
        seat_rules/2,               % -HardRules, -SoftRulesWithWeights
        custom_ids/3,               % +Level, +Strength (hard|soft), -Ids
        seat_conflict/6,            % +Rule, +Student, +Code, +Row, +Col, +Used
        seat_violations/3,          % +Rule, +Assignments, -Witnesses
        timetable_violations/2,     % +Rule, -Witnesses   (uses exam/2)
        explain_witness/3           % +Rule, +Witness, -Text
   ]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(assoc)).
:- use_module(library(aggregate)).
:- use_module(custom_rules).

:- dynamic active/3, next_id/1.

next_id(1).


% ===========================================================================
% 1. The catalogue: every kind of constraint the admin can add
% ===========================================================================
%
% catalog_entry(Name, Template, Level, Params, AllowedStrengths, Text)
%   Level    seat       checked for each seat the solver tries
%            room       changes which rooms / how much of a room is used
%            plan       measured on the finished plan (soft only)
%            timetable  checked when a subject is put in a session
%            custom     a rule written in Prolog (see custom_rules.pl)
%   Params   [Name:Type, ...]  Type = int | percent | room | date | time
%                                     | subject | session | level | text

catalog_entry(separation, separation(_N), seat, [n:int], [hard, soft],
    'Students sitting the same exam in the same row have at least N empty seats between them.').
catalog_entry(column_gap, column_gap(_N), seat, [n:int], [hard, soft],
    'Students sitting the same exam in the same column have at least N empty rows between them.').
catalog_entry(no_diagonal, no_diagonal, seat, [], [hard, soft],
    'Students sitting the same exam are never diagonal neighbours.').
catalog_entry(different_major_neighbours, different_major_neighbours, seat, [], [hard, soft],
    'Students side by side in a row are from different majors.').
catalog_entry(accessible_seats, accessible_seats, seat, [], [hard, soft],
    'Students who need an accessible seat sit on one.').
catalog_entry(room_fill, room_fill(_P), room, [p:percent], [hard],
    'Use at most P% of the seats of any room.').
catalog_entry(room_closed, room_closed(_R), room, [room:room], [hard],
    'Never use room R.').
catalog_entry(cohort_together, cohort_together, plan, [], [soft],
    'Keep each exam in as few rooms as possible (penalty per extra room).').
catalog_entry(session_fill, session_fill(_P), timetable, [p:percent], [hard],
    'A session holds at most P% of the open seats.').
catalog_entry(max_exams_per_day, max_exams_per_day(_K), timetable, [k:int], [hard, soft],
    'No student has more than K exams on one day.').
catalog_entry(no_back_to_back, no_back_to_back, timetable, [], [hard, soft],
    'No student has exams in two consecutive sessions of the same day.').
catalog_entry(no_exam_on, no_exam_on(_Date), timetable, [date:date], [hard],
    'No exams on this date (YYYY-MM-DD).').
catalog_entry(no_exam_at, no_exam_at(_Start), timetable, [start:time], [hard],
    'No exams in the slot starting at this time (HH:MM).').
catalog_entry(fixed_session, fixed_session(_Subject, _Session), timetable,
    [subject:subject, session:session], [hard],
    'This subject must be examined in this session.').
catalog_entry(custom, custom(_Level, _Name, _Text), custom,
    [level:level, name:text, rule:text], [hard, soft],
    'Your own rule in Prolog: violation(W) :- ... (see CONSTRAINTS.md).').

%! core_rule(?Name, ?Text)
%  What makes a seating plan a seating plan. Always on, cannot be removed.
core_rule(one_seat_per_student, 'Every student gets exactly one seat per exam.').
core_rule(seat_unique,          'No seat holds two students.').
core_rule(room_capacity,        'A room never holds more students than it has seats.').
core_rule(room_available,       'Rooms marked unavailable in the data are never used.').
core_rule(missing_student,      'Everyone with an exam in the session gets a seat.').
core_rule(exam_clash,           'No student has two exams in the same session.').

%! default_constraint(?Constraint, ?Strength)
%  The set the system starts with - the behaviour before constraints were
%  editable.
default_constraint(separation(1),        hard).
default_constraint(accessible_seats,     hard).
default_constraint(session_fill(80),     hard).
default_constraint(max_exams_per_day(1), soft(10)).

:- initialization(reset_constraints).


% ===========================================================================
% 2. Editing the knowledge base
% ===========================================================================

%! add_constraint(+Constraint, +Strength, -Id) is det.
%  Throws error(constraint(Message), _) when the constraint is malformed.
add_constraint(C, Strength, Id) :-
    check_constraint(C),
    check_strength(C, Strength),
    (   C = custom(Level, _, Text)
    ->  retract(next_id(Id)), Id1 is Id + 1, assertz(next_id(Id1)),
        catch(custom_rules:compile_rule(Id, Level, Text), E,
              ( retract(next_id(_)), assertz(next_id(Id)), throw(E) ))
    ;   retract(next_id(Id)), Id1 is Id + 1, assertz(next_id(Id1))
    ),
    assertz(active(Id, C, Strength)).

%! remove_constraint(+Id) is det.
remove_constraint(Id) :-
    retractall(active(Id, _, _)),
    custom_rules:forget_rule(Id).

%! set_strength(+Id, +Strength) is det.
set_strength(Id, Strength) :-
    active(Id, C, _),
    check_strength(C, Strength),
    retract(active(Id, C, _)),
    assertz(active(Id, C, Strength)).

reset_constraints :-
    clear_constraints,
    retractall(next_id(_)),
    assertz(next_id(1)),
    forall(default_constraint(C, S), add_constraint(C, S, _)).

clear_constraints :-
    forall(active(Id, _, _), remove_constraint(Id)).

fail_with(Format, Args) :-
    format(atom(Msg), Format, Args),
    throw(error(constraint(Msg), _)).

check_constraint(C) :-
    (   var(C) -> fail_with('Write a constraint, e.g. separation(2).', [])
    ;   true ),
    functor(C, Name, Arity),
    (   catalog_entry(Name, T, _, Params, _, _), functor(T, Name, Arity)
    ->  C =.. [_ | Args],
        findall(Type, member(_:Type, Params), Types),
        maplist(check_param(Name), Types, Args)
    ;   findall(N, catalog_entry(N, _, _, _, _, _), Names),
        atomic_list_concat(Names, ', ', Known),
        fail_with('Unknown constraint ~q. Known: ~w.', [C, Known])
    ).

check_param(_, int, V) :- integer(V), V >= 0, !.
check_param(N, int, V) :- !, fail_with('~w: ~q must be a whole number >= 0.', [N, V]).
check_param(_, percent, V) :- integer(V), V >= 1, V =< 100, !.
check_param(N, percent, V) :- !, fail_with('~w: ~q must be a percentage 1-100.', [N, V]).
check_param(_, room, R) :- atom(R), user:room(R, _, _, _), !.
check_param(N, room, R) :- !, fail_with('~w: there is no room ~q.', [N, R]).
check_param(_, date, D) :- atom(D), user:session_time(_, D, _, _), !.
check_param(N, date, D) :- !, fail_with('~w: no session on ~q (dates look like ''2026-12-01'').', [N, D]).
check_param(_, time, T) :- atom(T), user:session_time(_, _, T, _), !.
check_param(N, time, T) :- !, fail_with('~w: no session starts at ~q (times look like ''09:00'').', [N, T]).
check_param(_, subject, S) :- atom(S), user:subject(S), !.
check_param(N, subject, S) :- !, fail_with('~w: there is no subject ~q.', [N, S]).
check_param(_, session, S) :- atom(S), user:session_time(S, _, _, _), !.
check_param(N, session, S) :- !, fail_with('~w: there is no session ~q.', [N, S]).
check_param(_, level, L) :- memberchk(L, [seat, timetable]), !.
check_param(N, level, L) :- !, fail_with('~w: level must be seat or timetable, not ~q.', [N, L]).
check_param(_, text, T) :- ( atom(T) ; string(T) ), !.
check_param(N, text, T) :- fail_with('~w: ~q must be text.', [N, T]).

check_strength(C, Strength) :-
    functor(C, Name, _),
    catalog_entry(Name, _, _, _, Allowed, _),
    (   Strength == hard, memberchk(hard, Allowed)
    ->  true
    ;   Strength = soft(W), integer(W), W >= 1, memberchk(soft, Allowed)
    ->  true
    ;   Strength = soft(_), \+ memberchk(soft, Allowed)
    ->  fail_with('~w can only be hard.', [Name])
    ;   Strength == hard
    ->  fail_with('~w can only be soft.', [Name])
    ;   fail_with('Strength must be hard or soft(Weight) with Weight >= 1, not ~q.',
                  [Strength])
    ).

%! constraint_level(+Constraint, -Level) is det.
constraint_level(custom(Level, _, _), Level) :- !.
constraint_level(C, Level) :-
    functor(C, Name, _),
    catalog_entry(Name, _, Level, _, _, _).

%! describe(+Constraint, -Text) is det.
%  The constraint as a sentence, with its parameters filled in.
describe(separation(N), T) :- !,
    format(atom(T), 'Same-exam students in a row have at least ~d empty seat(s) between them', [N]).
describe(column_gap(N), T) :- !,
    format(atom(T), 'Same-exam students in a column have at least ~d empty row(s) between them', [N]).
describe(room_fill(P), T) :- !,
    format(atom(T), 'Use at most ~d% of the seats of any room', [P]).
describe(room_closed(R), T) :- !,
    format(atom(T), 'Never use room ~w', [R]).
describe(session_fill(P), T) :- !,
    format(atom(T), 'A session holds at most ~d% of the open seats', [P]).
describe(max_exams_per_day(K), T) :- !,
    format(atom(T), 'No student has more than ~d exam(s) on one day', [K]).
describe(no_exam_on(D), T) :- !,
    format(atom(T), 'No exams on ~w', [D]).
describe(no_exam_at(S), T) :- !,
    format(atom(T), 'No exams in the ~w slot', [S]).
describe(fixed_session(C, S), T) :- !,
    format(atom(T), '~w is examined in ~w', [C, S]).
describe(custom(Level, Name, _), T) :- !,
    format(atom(T), 'Custom ~w rule: ~w', [Level, Name]).
describe(C, T) :-
    functor(C, Name, _),
    (   catalog_entry(Name, _, _, _, _, T0) -> T = T0 ; format(atom(T), '~q', [C]) ).


% ===========================================================================
% 3. What the solvers ask
% ===========================================================================

%! hard_separation(-N) is det.  N = 0 when same-exam students may sit together.
hard_separation(N) :-
    findall(K, active(_, separation(K), hard), Ks),
    max_list([0 | Ks], N).

%! accessible_rule(-R) is det.  R = hard | soft(W) | off
accessible_rule(R) :-
    (   active(_, accessible_seats, S) -> R = S ; R = off ).

room_closed(R) :- active(_, room_closed(R), hard).

%! room_fill_percent(-P) is det.  100 when no room_fill constraint is active.
room_fill_percent(P) :-
    findall(Q, active(_, room_fill(Q), hard), Qs),
    min_list([100 | Qs], P).

%! session_fill_percent(-P) is det.
session_fill_percent(P) :-
    findall(Q, active(_, session_fill(Q), hard), Qs),
    min_list([100 | Qs], P).

%! blocked_session(?Session) is nondet.
blocked_session(S) :-
    user:session_time(S, Date, Start, _),
    (   active(_, no_exam_on(Date), hard)
    ;   active(_, no_exam_at(Start), hard)
    ),
    !.

fixed_session(Subject, Session) :-
    active(_, fixed_session(Subject, Session), hard).

%! student_day_rules(-Hard, -Soft) is det.
%  Hard = [max_per_day(K) | no_back_to_back], Soft = [Rule-Weight, ...]
student_day_rules(Hard, Soft) :-
    findall(R, ( active(_, C, hard), day_rule(C, R) ), Hard),
    findall(R-W, ( active(_, C, soft(W)), day_rule(C, R) ), Soft).

day_rule(max_exams_per_day(K), max_per_day(K)).
day_rule(no_back_to_back, no_back_to_back).

%! seat_rules(-Hard, -Soft) is det.
%  The seat-level rules the solver checks on each placement, apart from
%  hard separation and hard accessibility, which it handles itself.
seat_rules(Hard, Soft) :-
    findall(C, ( active(_, C, hard), extra_seat_rule(C) ), Hard),
    findall(C-W, ( active(_, C, soft(W)), seat_level(C) ), Soft).

extra_seat_rule(column_gap(_)).
extra_seat_rule(no_diagonal).
extra_seat_rule(different_major_neighbours).

seat_level(C) :- extra_seat_rule(C).
seat_level(separation(_)).
seat_level(accessible_seats).

%! custom_ids(+Level, +Kind, -Ids) is det.   Kind = hard | soft
custom_ids(Level, Kind, Ids) :-
    (   Kind == hard
    ->  findall(Id, active(Id, custom(Level, _, _), hard), Ids)
    ;   findall(Id, active(Id, custom(Level, _, _), soft(_)), Ids)
    ).


% ===========================================================================
% 4. Seat rules: one placement, and a whole plan
% ===========================================================================

%! seat_conflict(+Rule, +Student, +Code, +Row, +Col, +Used) is nondet.
%  Used maps Row-Col to p(Student, Code) for the seats already taken in the
%  room. Succeeds once per neighbour the placement would conflict with, so
%  \+ seat_conflict/6 is the hard check and aggregate_all(count, ...) is the
%  soft cost.
seat_conflict(separation(N), _, Code, Row, Col, Used) :-
    between(1, N, D),
    ( C2 is Col - D ; C2 is Col + D ),
    get_assoc(Row-C2, Used, p(_, Code)).
seat_conflict(column_gap(N), _, Code, Row, Col, Used) :-
    between(1, N, D),
    ( R2 is Row - D ; R2 is Row + D ),
    get_assoc(R2-Col, Used, p(_, Code)).
seat_conflict(no_diagonal, _, Code, Row, Col, Used) :-
    member(DR, [-1, 1]), member(DC, [-1, 1]),
    R2 is Row + DR, C2 is Col + DC,
    get_assoc(R2-C2, Used, p(_, Code)).
seat_conflict(different_major_neighbours, S, _, Row, Col, Used) :-
    user:student(S, Major, _, _),
    member(DC, [-1, 1]),
    C2 is Col + DC,
    get_assoc(Row-C2, Used, p(S2, _)),
    user:student(S2, Major, _, _).

%! seat_violations(+Rule, +Assignments, -Witnesses) is det.
%  Every place in a finished plan where Rule is broken, each pair once.
seat_violations(Rule, Assignments, Witnesses) :-
    plan_index(Assignments, Index),
    findall(W, seat_witness(Rule, Assignments, Index, W), Ws0),
    sort(Ws0, Witnesses).

plan_index(Assignments, Index) :-
    findall((R-Row-Col)-p(S, E), member(assign(S, E, R, Row, Col), Assignments), Ps),
    list_to_assoc(Ps, Index).

seat_witness(separation(N), As, Ix, too_close(S1, S2, E, R, Row, C1, C2)) :-
    member(assign(S1, E, R, Row, C1), As),
    between(1, N, D), C2 is C1 + D,
    get_assoc(R-Row-C2, Ix, p(S2, E)).
seat_witness(column_gap(N), As, Ix, same_column(S1, S2, E, R, R1, R2, C)) :-
    member(assign(S1, E, R, R1, C), As),
    between(1, N, D), R2 is R1 + D,
    get_assoc(R-R2-C, Ix, p(S2, E)).
seat_witness(no_diagonal, As, Ix, diagonal(S1, S2, E, R, R1, C1, R2, C2)) :-
    member(assign(S1, E, R, R1, C1), As),
    R2 is R1 + 1, member(DC, [-1, 1]), C2 is C1 + DC,
    get_assoc(R-R2-C2, Ix, p(S2, E)).
seat_witness(different_major_neighbours, As, Ix, same_major(S1, S2, M, R, Row, C1)) :-
    member(assign(S1, _, R, Row, C1), As),
    C2 is C1 + 1,
    get_assoc(R-Row-C2, Ix, p(S2, _)),
    user:student(S1, M, _, _), user:student(S2, M, _, _).
seat_witness(accessible_seats, As, _, not_accessible(S, R, Row, Col)) :-
    member(assign(S, _, R, Row, Col), As),
    rules:needs_accessible(S),
    \+ user:seat(R, Row, Col, accessible).
seat_witness(room_fill(P), As, _, too_full(R, N, Max)) :-
    findall(Room, member(assign(_, _, Room, _, _), As), Rooms0),
    msort(Rooms0, Rooms), clumped(Rooms, Counts),
    member(R-N, Counts),
    aggregate_all(count, user:seat(R, _, _, _), Cap),
    Max is Cap * P // 100,
    N > Max.
seat_witness(room_closed(R), As, _, used_closed_room(R, N)) :-
    aggregate_all(count, member(assign(_, _, R, _, _), As), N),
    N > 0.
seat_witness(cohort_together, As, _, split(E, Rooms)) :-
    findall(E0, member(assign(_, E0, _, _, _), As), Es0), sort(Es0, Es),
    member(E, Es),
    findall(R, member(assign(_, E, R, _, _), As), Rs0), sort(Rs0, Rooms),
    Rooms = [_, _ | _].
seat_witness(C, As, _, W) :-
    C = custom(seat, _, _),
    active(Id, C, _),
    custom_rules:plan_witness(Id, As, W).


% ===========================================================================
% 5. Timetable rules, on the exam/2 facts
% ===========================================================================

%! timetable_violations(+Rule, -Witnesses) is det.
timetable_violations(Rule, Witnesses) :-
    findall(W, tt_witness(Rule, W), Ws0),
    sort(Ws0, Witnesses).

tt_witness(session_fill(P), overfull(S, N, Max)) :-
    rules:total_capacity(Seats, _),
    Max is Seats * P // 100,
    user:session_time(S, _, _, _),
    aggregate_all(count, ( user:exam(C, S), user:enrolled(_, C) ), N),
    N > Max.
tt_witness(max_exams_per_day(K), too_many(St, Date, N)) :-
    student_day_counts(Counts),
    member((St-Date)-N, Counts),
    N > K.
tt_witness(no_back_to_back, back_to_back(St, S1, S2)) :-
    session_order(Order),
    user:enrolled(St, C1), user:exam(C1, S1),
    nth1(I, Order, S1), I2 is I + 1, nth1(I2, Order, S2),
    user:session_time(S1, D, _, _), user:session_time(S2, D, _, _),
    user:enrolled(St, C2), user:exam(C2, S2).
tt_witness(no_exam_on(D), exam_on(C, S, D)) :-
    user:session_time(S, D, _, _), user:exam(C, S).
tt_witness(no_exam_at(T), exam_at(C, S, T)) :-
    user:session_time(S, _, T, _), user:exam(C, S).
tt_witness(fixed_session(C, S), moved(C, S2, S)) :-
    user:exam(C, S2), S2 \== S.
tt_witness(C, W) :-
    C = custom(timetable, _, _),
    active(Id, C, _),
    custom_rules:timetable_witness(Id, W).

student_day_counts(Counts) :-
    findall(St-D, ( user:enrolled(St, C), user:exam(C, S),
                    user:session_time(S, D, _, _) ), Keys0),
    msort(Keys0, Keys),
    clumped(Keys, Counts).

session_order(Order) :-
    allocation:list_sessions(Order).


% ===========================================================================
% 6. Sentences for the UI
% ===========================================================================

explain_witness(_, too_close(S1, S2, E, R, Row, C1, C2), T) :- !,
    format(atom(T), '~w and ~w (~w) are too close in ~w row ~w, columns ~w and ~w',
           [S1, S2, E, R, Row, C1, C2]).
explain_witness(_, same_column(S1, S2, E, R, R1, R2, C), T) :- !,
    format(atom(T), '~w and ~w (~w) are too close in ~w column ~w, rows ~w and ~w',
           [S1, S2, E, R, C, R1, R2]).
explain_witness(_, diagonal(S1, S2, E, R, R1, C1, R2, C2), T) :- !,
    format(atom(T), '~w and ~w (~w) are diagonal neighbours in ~w (R~wC~w, R~wC~w)',
           [S1, S2, E, R, R1, C1, R2, C2]).
explain_witness(_, same_major(S1, S2, M, R, Row, C), T) :- !,
    upcase_atom(M, MU), C2 is C + 1,
    format(atom(T), '~w and ~w, both ~w, sit side by side in ~w row ~w (columns ~w and ~w)',
           [S1, S2, MU, R, Row, C, C2]).
explain_witness(_, not_accessible(S, R, Row, Col), T) :- !,
    format(atom(T), '~w needs an accessible seat but sits at ~w R~wC~w', [S, R, Row, Col]).
explain_witness(_, too_full(R, N, Max), T) :- !,
    format(atom(T), '~w holds ~d students, more than its limit of ~d', [R, N, Max]).
explain_witness(_, used_closed_room(R, N), T) :- !,
    format(atom(T), 'closed room ~w is used by ~d students', [R, N]).
explain_witness(_, split(E, Rooms), T) :- !,
    length(Rooms, N), atomic_list_concat(Rooms, ', ', RA),
    format(atom(T), '~w is split over ~d rooms (~w)', [E, N, RA]).
explain_witness(_, overfull(S, N, Max), T) :- !,
    format(atom(T), '~w has ~d students, more than ~d', [S, N, Max]).
explain_witness(_, too_many(St, D, N), T) :- !,
    format(atom(T), '~w has ~d exams on ~w', [St, N, D]).
explain_witness(_, back_to_back(St, S1, S2), T) :- !,
    format(atom(T), '~w has exams in ~w and ~w back to back', [St, S1, S2]).
explain_witness(_, exam_on(C, S, D), T) :- !,
    format(atom(T), '~w is in ~w, on ~w', [C, S, D]).
explain_witness(_, exam_at(C, S, Time), T) :- !,
    format(atom(T), '~w is in ~w, at ~w', [C, S, Time]).
explain_witness(_, moved(C, S2, S), T) :- !,
    format(atom(T), '~w is in ~w, not in ~w', [C, S2, S]).
explain_witness(_, W, T) :-
    format(atom(T), '~q', [W]).
