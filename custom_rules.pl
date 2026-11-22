% ===========================================================================
% custom_rules.pl  -  constraints the admin writes in Prolog
% ===========================================================================
% A custom constraint is one or more clauses
%
%     violation(Witness) :- Body.
%
% "the plan is broken wherever Body is true". Seat rules see the seating
% plan, timetable rules see the timetable, through a small vocabulary
% (below). Each rule is compiled into this module as
%
%     rule(Id, Witness) :- Body.
%
% The body may only call the vocabulary, arithmetic, comparison and a few
% list predicates - no I/O, no assert, no calling arbitrary goals - so a
% typed-in rule cannot touch anything outside the plan it is checking.
%
% During the search the current partial plan sits in a backtrackable global
% variable (b_setval/2), so a hard custom rule prunes the search exactly like
% a built-in one: after each placement, \+ rule(Id, _) must hold.
% ===========================================================================

:- module(custom_rules, [
        compile_rule/3,             % +Id, +Level, +Text
        forget_rule/1,              % +Id
        seat_rules_ok/2,            % +Ids, +PartialAssignments
        timetable_rules_ok/2,       % +Ids, +AssignAssoc
        plan_witness/3,             % +Id, +Assignments, -Witness
        timetable_witness/2,        % +Id, -Witness
        vocabulary/3                % ?Level, ?Head, ?Text
   ]).

:- use_module(library(lists)).
:- use_module(library(assoc)).

:- dynamic rule/2, rule_level/2.

:- initialization(( nb_setval(ses_plan, []), empty_assoc(E), nb_setval(ses_tt, E) )).


% ===========================================================================
% 1. The vocabulary a rule may use
% ===========================================================================

%! vocabulary(?Level, ?Head, ?Text)   - also listed in CONSTRAINTS.md
vocabulary(seat, seated(student, exam, room, row, col),
           'student sits exam in room at row, col (the plan being checked)').
vocabulary(seat, next_to(s1, s2),   's1 and s2 sit side by side in a row').
vocabulary(seat, behind(s1, s2),    's2 sits directly behind s1').
vocabulary(seat, diagonal(s1, s2),  's1 and s2 are diagonal neighbours').
vocabulary(seat, same_exam(s1, s2), 's1 and s2 sit the same exam').
vocabulary(seat, seat_type(room, row, col, type), 'type is normal or accessible').
vocabulary(seat, room_size(room, rows, cols), 'the size of a room').
vocabulary(timetable, exam_session(exam, session), 'exam is held in session (the timetable being checked)').
vocabulary(timetable, takes(student, exam),       'student is enrolled in exam').
vocabulary(timetable, session_date(session, date),   'e.g. ''2026-12-01''').
vocabulary(timetable, session_start(session, time),  'e.g. ''09:00''').
vocabulary(timetable, session_weekday(session, day), 'mon, tue, wed, thu, fri, sat or sun').
vocabulary(timetable, session_index(session, n),     '1 for the first session, 2 for the next, ...').
vocabulary(timetable, exam_size(exam, n),            'how many students sit exam').
vocabulary(both, student(student, major, year, access), 'access is none, wheelchair or other_accessible').
vocabulary(both, major(student, major), 'e.g. se').
vocabulary(both, year(student, year),   '1, 2, 3 or 4').
vocabulary(both, needs_accessible(student), 'student needs an accessible seat').
vocabulary(both, exam_cohort(exam, major, year), 'exam belongs to that (major, year) cohort').

% --- seat level ---------------------------------------------------------
seated(S, E, R, Row, Col) :-
    b_getval(ses_plan, Plan),
    member(assign(S, E, R, Row, Col), Plan).
next_to(S1, S2) :-
    seated(S1, _, R, Row, C1), seated(S2, _, R, Row, C2),
    1 =:= abs(C1 - C2).
behind(S1, S2) :-
    seated(S1, _, R, R1, C), seated(S2, _, R, R2, C),
    R2 =:= R1 + 1.
diagonal(S1, S2) :-
    seated(S1, _, R, R1, C1), seated(S2, _, R, R2, C2),
    1 =:= abs(R1 - R2), 1 =:= abs(C1 - C2).
same_exam(S1, S2) :-
    seated(S1, E, _, _, _), seated(S2, E, _, _, _), S1 \== S2.
seat_type(R, Row, Col, T) :- user:seat(R, Row, Col, T).
room_size(R, Rows, Cols)  :- user:room(R, Rows, Cols, _).

% --- timetable level ----------------------------------------------------
exam_session(E, S) :-
    b_getval(ses_tt, A),
    (   nonvar(E) -> get_assoc(E, A, S) ; gen_assoc(E, A, S) ).
takes(St, E)             :- user:enrolled(St, E).
session_date(S, D)       :- user:session_time(S, D, _, _).
session_start(S, T)      :- user:session_time(S, _, T, _).
session_weekday(S, W) :-
    user:session_time(S, D, _, _),
    atomic_list_concat([Y, M, Dd], '-', D),
    atom_number(Y, Yn), atom_number(M, Mn), atom_number(Dd, Dn),
    day_of_the_week(date(Yn, Mn, Dn), N),
    nth1(N, [mon, tue, wed, thu, fri, sat, sun], W).
session_index(S, I) :-
    allocation:list_sessions(Ss), nth1(I, Ss, S).
exam_size(E, N) :-
    user:subject(E), aggregate_all(count, user:enrolled(_, E), N).

% --- both ---------------------------------------------------------------
student(S, M, Y, A)     :- user:student(S, M, Y, A).
major(S, M)             :- user:student(S, M, _, _).
year(S, Y)              :- user:student(S, _, Y, _).
needs_accessible(S)     :- rules:needs_accessible(S).
exam_cohort(E, M, Y) :-
    (   nonvar(E)
    ->  once(( user:enrolled(St, E), user:student(St, M, Y, _) ))
    ;   user:subject(E), once(( user:enrolled(St, E), user:student(St, M, Y, _) ))
    ).


% ===========================================================================
% 2. Compiling a rule safely
% ===========================================================================

%! compile_rule(+Id, +Level, +Text) is det.
%  Throws error(constraint(Message), _) with a readable message.
compile_rule(Id, Level, Text) :-
    read_clauses(Text, Clauses),
    (   Clauses == []
    ->  fail_with('The rule is empty. Write violation(W) :- ... .', [])
    ;   true ),
    maplist(check_clause(Level), Clauses),
    forget_rule(Id),
    forall(member(C, Clauses), add_clause(Id, C)),
    assertz(rule_level(Id, Level)).

forget_rule(Id) :-
    retractall(rule(Id, _)),
    retractall(rule_level(Id, _)).

add_clause(Id, (violation(W) :- Body)) :- !,
    assertz((rule(Id, W) :- Body)).
add_clause(Id, violation(W)) :-
    assertz(rule(Id, W)).

fail_with(Format, Args) :-
    format(atom(Msg), Format, Args),
    throw(error(constraint(Msg), _)).

read_clauses(Text, Clauses) :-
    (   string(Text) -> S = Text ; atom_string(Text, S) ),
    catch(term_string_all(S, Clauses), E,
          ( message_to_codes(E, Msg), fail_with('Prolog syntax error: ~s', [Msg]) )).

term_string_all(S, Clauses) :-
    setup_call_cleanup(
        open_string(S, In),
        read_all(In, Clauses),
        close(In)).

read_all(In, Clauses) :-
    read_term(In, T, [module(custom_rules)]),
    (   T == end_of_file
    ->  Clauses = []
    ;   Clauses = [T | Rest],
        read_all(In, Rest)
    ).

message_to_codes(E, Codes) :-
    (   E = error(syntax_error(What), _)
    ->  format(codes(Codes), '~w', [What])
    ;   format(codes(Codes), '~q', [E])
    ).

check_clause(Level, (violation(_) :- Body)) :- !,
    check_body(Level, Body).
check_clause(_, violation(_)) :- !.
check_clause(_, C) :-
    fail_with('Each clause must look like violation(W) :- ..., not ~q.', [C]).

check_body(_, G) :-
    var(G), !,
    fail_with('A variable cannot be called as a goal.', []).
check_body(L, (A, B))   :- !, check_body(L, A), check_body(L, B).
check_body(L, (A ; B))  :- !, check_body(L, A), check_body(L, B).
check_body(L, (A -> B)) :- !, check_body(L, A), check_body(L, B).
check_body(L, \+ A)     :- !, check_body(L, A).
check_body(L, G) :-
    functor(G, Name, Arity),
    (   allowed(L, Name/Arity)
    ->  true
    ;   fail_with('~w/~w is not allowed in a ~w rule. See CONSTRAINTS.md for what you can use.',
                  [Name, Arity, L])
    ).

allowed(_, Name/Arity) :- builtin_ok(Name/Arity), !.
allowed(L, Name/Arity) :-
    vocabulary(V, Head, _),
    ( V == L ; V == both ),
    functor(Head, Name, Arity), !.

builtin_ok(true/0).          builtin_ok(fail/0).
builtin_ok((=)/2).           builtin_ok((\=)/2).
builtin_ok((==)/2).          builtin_ok((\==)/2).
builtin_ok((@<)/2).          builtin_ok((@>)/2).
builtin_ok((@=<)/2).         builtin_ok((@>=)/2).
builtin_ok((<)/2).           builtin_ok((>)/2).
builtin_ok((=<)/2).          builtin_ok((>=)/2).
builtin_ok((=:=)/2).         builtin_ok((=\=)/2).
builtin_ok((is)/2).
builtin_ok(member/2).        builtin_ok(memberchk/2).
builtin_ok(between/3).       builtin_ok(atom_concat/3).
builtin_ok(sub_atom/5).      builtin_ok(atom/1).
builtin_ok(number/1).        builtin_ok(integer/1).


% ===========================================================================
% 3. Using the rules
% ===========================================================================

%! seat_rules_ok(+Ids, +Plan) is semidet.
%  No hard seat rule is broken by the partial plan.
seat_rules_ok([], _) :- !.
seat_rules_ok(Ids, Plan) :-
    b_setval(ses_plan, Plan),
    \+ ( member(Id, Ids), rule(Id, _) ).

%! timetable_rules_ok(+Ids, +Assoc) is semidet.
timetable_rules_ok([], _) :- !.
timetable_rules_ok(Ids, Assoc) :-
    b_setval(ses_tt, Assoc),
    \+ ( member(Id, Ids), rule(Id, _) ).

%! plan_witness(+Id, +Assignments, -Witness) is nondet.
plan_witness(Id, Assignments, W) :-
    b_setval(ses_plan, Assignments),
    bounded_witnesses(Id, Ws),
    member(W, Ws).

%! timetable_witness(+Id, -Witness) is nondet.
timetable_witness(Id, W) :-
    findall(C-S, user:exam(C, S), Pairs),
    list_to_assoc(Pairs, A),
    b_setval(ses_tt, A),
    bounded_witnesses(Id, Ws),
    member(W, Ws).

% A badly written rule must not hang the app: give it a generous budget and
% report when it runs out.
bounded_witnesses(Id, Ws) :-
    catch(call_with_inference_limit(findall(W, rule(Id, W), Ws0), 50_000_000, R),
          E, ( Ws0 = [rule_error(Id, E)], R = error )),
    (   R == inference_limit_exceeded
    ->  Ws = [rule_too_slow(Id)]
    ;   sort(Ws0, Ws)
    ).
