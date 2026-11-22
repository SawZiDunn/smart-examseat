% ===========================================================================
% timetable.pl  -  exam timetabling CSP                        (Member A)
% ===========================================================================
% Decides WHICH SESSION each subject is examined in, before any seating.
%
%   Variables   one per subject
%   Domain      the sessions of the exam period (session_time/4 facts)
%   Hard        - two subjects that share a student are in different sessions
%                 (so nobody ever has two exams at once: the exam_clash rule)
%               - a session's headcount  <= open seats x max fill %
%               - a session's accessible headcount <= accessible seats
%   Soft        - a student should not have two exams on the same day
%               - spread the load evenly over the exam period
%
%   Search      backtracking (member/2 over an ordered domain)
%   Variable    largest subject first, then most conflicts (fail-first)
%   Value       session with fewest same-day conflicts, then the emptiest
%               session (least constraining: keeps room for what follows)
%
% The result is ordinary exam(Subject, Session) facts, so allocation, the
% seat solver, the validator and the UI are unaware the timetable was
% generated. generate_data.py runs timetable_cli/1 and writes those facts
% into data.pl.
% ===========================================================================

:- module(timetable, [
        build_timetable/2,          % +Options, -Result
        timetable_cli/1,            % +Options   (used by generate_data.py)
        explain_timetable_failure/2
   ]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(assoc)).
:- use_module(rules).
:- use_module(allocation, [list_sessions/1]).
:- use_module(constraints, []).
:- use_module(custom_rules, []).

:- dynamic
        user:student/4,
        user:subject/1,
        user:enrolled/2,
        user:session_time/4.

default_fill(80).
default_budget(50_000_000).


% ===========================================================================
% build_timetable/2
% ===========================================================================

%! build_timetable(+Options, -Result) is det.
%
%  Options  fill(Percent)   max share of the open seats one session may use
%                           (default: the session_fill(P) constraint)
%           budget(N)       inference limit for the search
%
%  Every other rule comes from the constraint knowledge base (constraints.pl):
%  blocked days and slots, fixed subjects, per-student day rules (hard ones
%  prune, soft ones order the sessions), and custom timetable rules.
%
%  Result   ok(Timetable, Stats)
%             Timetable = [Subject-Session, ...]
%             Stats     = stats(SameDayPairs, PeakLoad, Limit, Sessions)
%         | failed(Reason)
%             Reason    = no_sessions
%                       | subject_too_large(Subject, Size, Max)
%                       | too_few_sessions(Needed, Have)
%                       | too_few_days(Needed, Have)
%                       | fixed_blocked(Subject, Session)
%                       | no_timetable(Sessions)
build_timetable(Options, Result) :-
    (   memberchk(fill(Fill), Options)
    ->  true
    ;   constraints:session_fill_percent(Fill)
    ),
    option_or(budget(Budget), Options, default_budget),
    session_slots(Slots),
    subject_infos(Infos),
    rules:total_capacity(Seats, ASeats),
    aggregate_all(sum(U), rules:usable_capacity(_, U), Usable),
    Limit is min(Seats * Fill // 100, Usable),
    constraints:student_day_rules(DayHard, DaySoft),
    constraints:custom_ids(timetable, hard, CustomIds),
    (   precheck(Slots, Infos, Limit, ASeats, DayHard, Reason)
    ->  Result = failed(Reason)
    ;   order_subjects(Infos, Ordered),
        initial_loads(Slots, Loads0),
        empty_assoc(Assign0),
        empty_assoc(Hist0),
        length(Slots, NSlots),
        Ctx = ctx(Slots, Limit, ASeats, DayHard, DaySoft, CustomIds),
        (   catch(call_with_inference_limit(
                      place(Ordered, Ctx, Assign0, Loads0, Hist0, Assign, Loads),
                      Budget, Outcome),
                  _, Outcome = exception),
            Outcome \== inference_limit_exceeded,
            Outcome \== exception
        ->  assoc_to_list(Assign, Timetable),
            same_day_pairs(Infos, Assign, Slots, SameDay),
            assoc_to_values(Loads, LoadPairs),
            pairs_keys(LoadPairs, Ls),
            max_list([0 | Ls], Peak),
            Result = ok(Timetable, stats(SameDay, Peak, Limit, NSlots))
        ;   Result = failed(no_timetable(NSlots))
        )
    ),
    !.

option_or(Opt, Options, Default) :-
    (   memberchk(Opt, Options)
    ->  true
    ;   arg(1, Opt, V), call(Default, V)
    ).


% ---------------------------------------------------------------------------
% Problem description
% ---------------------------------------------------------------------------

%! session_slots(-Slots) is det.
%  Slots = [slot(Session, Date, Index), ...] in calendar order, without the
%  sessions a no_exam_on/no_exam_at constraint blocks. Index is the
%  position in the full list, so consecutive sessions stay consecutive.
session_slots(Slots) :-
    list_sessions(Sessions),
    findall(slot(S, Date, I),
            ( nth1(I, Sessions, S), user:session_time(S, Date, _, _),
              \+ constraints:blocked_session(S) ),
            Slots).

%! subject_infos(-Infos) is det.
%  Infos = [info(Subject, Size, AccessibleSize, ConflictingSubjects,
%                Students), ...]
subject_infos(Infos) :-
    findall(St-C, user:enrolled(St, C), Enrol0),
    sort(Enrol0, Enrol),
    group_pairs_by_key(Enrol, ByStudent),           % Student-[Subjects]
    findall(A-B,
            ( member(_-Cs, ByStudent),
              member(A, Cs), member(B, Cs), A \== B ),
            Edges0),
    sort(Edges0, Edges),
    group_pairs_by_key(Edges, ConflictGroups),      % Subject-[Subjects]
    list_to_assoc(ConflictGroups, Conflicts),
    findall(info(C, Size, ASize, Cf, Students),
            ( user:subject(C),
              findall(St, user:enrolled(St, C), Students),
              length(Students, Size),
              aggregate_all(count,
                            ( member(St, Students),
                              rules:requires_accessible_seat(St) ),
                            ASize),
              ( get_assoc(C, Conflicts, Cf) -> true ; Cf = [] ) ),
            Infos).

%! precheck(+Slots, +Infos, +Limit, +ASeats, +DayHard, -Reason) is semidet.
%  Cheap lower bounds that prove there is no timetable without searching.
precheck([], _, _, _, _, no_sessions) :- !.
precheck(Slots, Infos, _, _, _, fixed_blocked(C, S)) :-
    member(info(C, _, _, _, _), Infos),
    constraints:fixed_session(C, S),
    \+ memberchk(slot(S, _, _), Slots),
    !.
precheck(_, Infos, Limit, _, _, subject_too_large(C, Size, Max)) :-
    aggregate_all(sum(M), rules:max_same_exam_per_room(_, M), SepMax),
    Max is min(Limit, SepMax),
    member(info(C, Size, _, _, _), Infos),
    Size > Max,
    !.
precheck(Slots, _, _, _, DayHard, too_few_days(Need, Have)) :-
    % with at most K exams a day, a student with M exams needs ceil(M/K) days
    findall(K, member(max_per_day(K), DayHard), Ks),
    Ks \== [],
    min_list(Ks, K0), K is max(1, K0),
    max_exams_per_student(MaxM),
    findall(D, member(slot(_, D, _), Slots), Ds0), sort(Ds0, Ds),
    length(Ds, Have),
    ceil_div(MaxM, K, Need),
    Need > Have,
    !.
precheck(Slots, Infos, Limit, ASeats, _, too_few_sessions(Need, Have)) :-
    length(Slots, Have),
    % a student with K exams needs K different sessions
    max_exams_per_student(MaxK),
    % every exam seat has to fit somewhere
    aggregate_all(sum(S), member(info(_, S, _, _, _), Infos), Total),
    aggregate_all(sum(A), member(info(_, _, A, _, _), Infos), ATotal),
    ceil_div(Total, Limit, NeedSeats),
    ceil_div(ATotal, ASeats, NeedAccess),
    Need is max(MaxK, max(NeedSeats, NeedAccess)),
    Need > Have,
    !.

max_exams_per_student(Max) :-
    findall(K, ( user:student(St, _, _, _),
                 aggregate_all(count, user:enrolled(St, _), K) ), Ks),
    max_list([0 | Ks], Max).

ceil_div(0, _, 0) :- !.
ceil_div(_, 0, 1_000_000) :- !.                     % nothing to put it in
ceil_div(X, Y, Z) :- Z is (X + Y - 1) // Y.

%! order_subjects(+Infos, -Ordered) is det.
%  Variable ordering: subjects pinned by fixed_session first (one value
%  left), then biggest subject first, ties broken by most conflicts.
order_subjects(Infos, Ordered) :-
    findall(k(Pinned, NegSize, NegDeg, C)-I,
            ( member(I, Infos), I = info(C, Size, _, Cf, _),
              ( constraints:fixed_session(C, _) -> Pinned = 0 ; Pinned = 1 ),
              NegSize is -Size, length(Cf, D), NegDeg is -D ),
            Keyed),
    keysort(Keyed, Sorted),
    pairs_values(Sorted, Ordered).

initial_loads(Slots, Loads) :-
    findall(S-(0-0), member(slot(S, _, _), Slots), Pairs),
    list_to_assoc(Pairs, Loads).


% ---------------------------------------------------------------------------
% The search
% ---------------------------------------------------------------------------

%! place(+Subjects, +Ctx, +Assign0, +Loads0, +Hist0, -Assign, -Loads)
%! is nondet.
%  Assign: Subject -> Session.  Loads: Session -> Students-AccessibleStudents.
%  Hist:   Student -> [Index-Date, ...], the sessions each student already
%          has, for the per-student day rules.
place([], _, Assign, Loads, _, Assign, Loads).
place([Info | Rest], Ctx, A0, L0, H0, A, L) :-
    Info = info(C, Size, ASize, _, Students),
    candidates(Info, Ctx, A0, L0, H0, Ordered),
    member(slot(S, Date, I), Ordered),               % choice point
    put_assoc(C, A0, S, A1),
    Ctx = ctx(_, _, _, _, _, CustomIds),
    custom_rules:timetable_rules_ok(CustomIds, A1),  % rules typed in Prolog
    get_assoc(S, L0, N0-NA0),
    N1 is N0 + Size, NA1 is NA0 + ASize,
    put_assoc(S, L0, N1-NA1, L1),
    foldl(add_history(I-Date), Students, H0, H1),
    place(Rest, Ctx, A1, L1, H1, A, L).

add_history(Entry, St, H0, H) :-
    ( get_assoc(St, H0, Es) -> true ; Es = [] ),
    put_assoc(St, H0, [Entry | Es], H).

%! candidates(+Info, +Ctx, +Assign, +Loads, +Hist, -Slots)
%  The legal sessions for one subject, best first: hard rules filter,
%  soft rules give each session a penalty, and the cheapest come first
%  (ties: the emptiest session, then the earliest).
candidates(info(C, Size, ASize, Cf, Students),
           ctx(Slots, Limit, ALimit, DayHard, DaySoft, _),
           Assign, Loads, Hist, Ordered) :-
    conflict_slots(Cf, Assign, Taken),               % sessions of neighbours
    ( constraints:fixed_session(C, Fixed) -> true ; Fixed = _ ),
    findall(k(Cost, N, I)-slot(S, Date, I),
            ( member(slot(S, Date, I), Slots),
              ( var(Fixed) -> true ; S == Fixed ),   % hard: fixed_session
              \+ memberchk(S-_, Taken),               % hard: no clash
              get_assoc(S, Loads, N-NA),
              N + Size =< Limit,                      % hard: seats
              NA + ASize =< ALimit,                   % hard: accessible seats
              day_rules_ok(DayHard, Students, Date, I, Hist),
              day_cost(DaySoft, Students, Date, I, Hist, Cost) ),
            Keyed),
    keysort(Keyed, Sorted),
    pairs_values(Sorted, Ordered).

%! day_rules_ok(+HardRules, +Students, +Date, +Index, +Hist) is semidet.
%  No student of the subject would break a hard per-student day rule.
day_rules_ok([], _, _, _, _) :- !.
day_rules_ok(Rules, Students, Date, I, Hist) :-
    \+ ( member(St, Students),
          get_assoc(St, Hist, Had),
          member(R, Rules),
          breaks(R, Had, Date, I) ).

%! day_cost(+SoftRules, +Students, +Date, +Index, +Hist, -Cost) is det.
%  Weight x number of students who would break each soft day rule.
day_cost([], _, _, _, _, 0) :- !.
day_cost(Rules, Students, Date, I, Hist, Cost) :-
    aggregate_all(sum(W),
                  ( member(R-W, Rules),
                    member(St, Students),
                    get_assoc(St, Hist, Had),
                    breaks(R, Had, Date, I) ),
                  Cost).

%! breaks(+Rule, +Had, +Date, +Index) is semidet.
%  Adding a session (Index, Date) to a student who already has Had breaks Rule.
breaks(max_per_day(K), Had, Date, _) :-
    aggregate_all(count, member(_-Date, Had), N),
    N >= K.
breaks(no_back_to_back, Had, Date, I) :-
    ( I2 is I - 1 ; I2 is I + 1 ),
    memberchk(I2-Date, Had), !.

%! conflict_slots(+Conflicts, +Assign, -Taken) is det.
%  Taken = [Session-Date, ...] for every already-placed conflicting subject.
conflict_slots(Cf, Assign, Taken) :-
    findall(S-Date,
            ( member(X, Cf), get_assoc(X, Assign, S),
              user:session_time(S, Date, _, _) ),
            Taken).

%! same_day_pairs(+Infos, +Assign, +Slots, -N) is det.
%  Soft-constraint score: pairs of conflicting subjects on the same day.
same_day_pairs(Infos, Assign, _Slots, N) :-
    aggregate_all(count,
                  ( member(info(C, _, _, Cf, _), Infos),
                    member(X, Cf), C @< X,
                    get_assoc(C, Assign, S1), get_assoc(X, Assign, S2),
                    user:session_time(S1, D, _, _),
                    user:session_time(S2, D, _, _) ),
                  N).


% ===========================================================================
% Messages and the command-line entry point
% ===========================================================================

%! explain_timetable_failure(+Reason, -Text) is det.
explain_timetable_failure(no_sessions, Text) :- !,
    Text = 'The exam period has no sessions (check [exam_period] in config.toml).'.
explain_timetable_failure(subject_too_large(C, Size, Max), Text) :- !,
    format(atom(Text),
           'Subject ~w has ~d students but one session can hold at most ~d \c
            of one exam. Add rooms or raise max_fill_percent.',
           [C, Size, Max]).
explain_timetable_failure(too_few_sessions(Need, Have), Text) :- !,
    format(atom(Text),
           'The exams need at least ~d sessions but the exam period has ~d. \c
            Add exam days or rooms in config.toml, or relax a constraint.',
           [Need, Have]).
explain_timetable_failure(too_few_days(Need, Have), Text) :- !,
    format(atom(Text),
           'With the max_exams_per_day limit a student needs at least ~d exam days, \c
            but there are ~d. Add days or relax the limit.', [Need, Have]).
explain_timetable_failure(fixed_blocked(C, S), Text) :- !,
    format(atom(Text),
           '~w is fixed to ~w, but another constraint blocks that session.', [C, S]).
explain_timetable_failure(no_timetable(N), Text) :- !,
    format(atom(Text),
           'No timetable fits the ~d sessions within the search budget. \c
            Add exam days or rooms in config.toml.', [N]).
explain_timetable_failure(Reason, Text) :-
    format(atom(Text), '~q', [Reason]).

%! timetable_cli(+Options) is det.
%  Prints the timetable as exam/2 facts on stdout, or FAILED: <why> and
%  exits with status 1. generate_data.py parses this output.
timetable_cli(Options) :-
    build_timetable(Options, Result),
    (   Result = ok(Timetable, stats(SameDay, Peak, Limit, NSlots))
    ->  format("% timetable: ~d sessions, peak load ~d / ~d, \c
                ~d same-day exam pairs~n",
               [NSlots, Peak, Limit, SameDay]),
        forall(member(C-S, Timetable), format("exam(~q, ~q).~n", [C, S]))
    ;   Result = failed(Reason),
        explain_timetable_failure(Reason, Text),
        format("FAILED: ~w~n", [Text]),
        halt(1)
    ).
