% ===========================================================================
% demo.pl  -  console demonstration of the whole pipeline
% ===========================================================================
%     swipl -q -g demo -t halt demo.pl
%     swipl -q -g "demo_session(sess1)" -t halt demo.pl
%     swipl -q -g "demo_room(sess1, r101)" -t halt demo.pl
% ===========================================================================

:- ensure_loaded(main).

%! demo is det.
%  Solve and validate every session, printing a one-line summary each.
demo :-
    format("~nSmartExamSeat - solving every session~n"),
    format("~`-t~60|~n"),
    format("~w~t~10| ~w~t~22| ~w~t~32| ~w~t~44| ~w~n",
           ['session', 'students', 'rooms', 'retries', 'validator']),
    format("~`-t~60|~n"),
    list_sessions(Sessions),
    forall(member(S, Sessions), demo_line(S)),
    format("~`-t~60|~n~n").

demo_line(Session) :-
    generate_seating(Session, filters([], []), Result,
                     stats(NStudents, NRooms, Retries, Millis)),
    (   Result = ok(Assignments)
    ->  validate_seating(Session, filters([], []), Assignments, Report),
        ( Report == valid
        -> Status = valid
        ;  Report = invalid(Vs), length(Vs, NV),
           format(atom(Status), 'INVALID(~d)', [NV]) )
    ;   Result = failed(Reason),
        format(atom(Status), 'FAILED ~q', [Reason])
    ),
    format("~w~t~10| ~d~t~22| ~d~t~32| ~d~t~44| ~w (~d ms)~n",
           [Session, NStudents, NRooms, Retries, Status, Millis]).

%! demo_session(+Session) is det.
%  Full detail for one session: the room split plus the validator report.
demo_session(Session) :-
    generate_seating(Session, filters([], []), Result, Stats),
    format("~n~w  ~q~n", [Session, Stats]),
    print_result(Result),
    (   Result = ok(Assignments)
    ->  validate_seating(Session, filters([], []), Assignments, Report),
        print_report(Report)
    ;   true
    ).

%! demo_room(+Session, +RoomId) is det.
%  Print one room's seat grid as ASCII.
demo_room(Session, RoomId) :-
    generate_seating(Session, filters([], []), ok(Assignments)),
    include_room(RoomId, Assignments, Mine),
    print_room(RoomId, Mine).

include_room(RoomId, Assignments, Mine) :-
    include([assign(_, _, R, _, _)]>>(R == RoomId), Assignments, Mine).

print_report(valid) :- !,
    format("validator: valid~n").
print_report(invalid(Violations)) :-
    length(Violations, N),
    format("validator: ~d violation(s)~n", [N]),
    forall(member(V, Violations),
           ( explain_violation(V, Text), format("  - ~w~n", [Text]) )).
