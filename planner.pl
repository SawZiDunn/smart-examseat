% ===========================================================================
% planner.pl  -  how many days, slots and rooms do these students need?
% ===========================================================================
% The data fixes the students and their subjects. The planner varies the
% resources: the exam period (days x slots per day) and the rooms (a pool of
% mixed sizes). For one option it
%
%   1. replaces the session_time/4, room/4 and seat/4 facts with the option,
%   2. runs evaluate/1 (main.pl) under the ACTIVE constraints: a timetable,
%      every session seated, every hard rule re-checked, the soft penalty,
%   3. puts the original facts back,
%
% and scores it:
%
%   score = days x DayCost + rooms needed x RoomCost + soft penalty
%
% Options that cannot work are usually rejected by the timetabler's lower
% bounds (too few sessions, too few days, a subject too large) without any
% search. The browser asks for one option at a time, so the table of results
% fills in as the planner works.
% ===========================================================================

:- module(planner, [
        plan_option/3,          % +Option, +Weights, -Result
        apply_option/1,         % +Option
        weekdays/3              % +StartDate, +N, -Dates
   ]).

:- use_module(library(lists)).
:- use_module(library(apply)).

:- dynamic
        user:session_time/4,
        user:room/4,
        user:seat/4,
        user:exam/2.

% Option  = option(Days, Slots, StartDate, Pool)
%   Slots = [Start-End, ...]        e.g. ['09:00'-'12:00', '13:00'-'16:00']
%   Pool  = [pool(Rows, Cols, Count), ...]
% Weights = weights(DayCost, RoomCost)
% Result  = result(Feasible, Why, Sessions, Rooms, Penalty, Score, Report)


%! plan_option(+Option, +Weights, -Result) is det.
%  Evaluates the option and restores the loaded setup afterwards.
plan_option(Option, weights(DayCost, RoomCost), Result) :-
    save_setup(Saved),
    setup_call_cleanup(
        install_option(Option),
        user:evaluate(Report),
        restore_setup(Saved)),
    Option = option(Days, _, _, _),
    Report = report(Feasible, Problems, _, _, rooms(_, _, BySize), _, Penalty, _),
    aggregate_all(sum(N), member(size(_, _, _, N, _), BySize), RoomsNeeded),
    (   Feasible == true
    ->  Why = '',
        Score is Days * DayCost + RoomsNeeded * RoomCost + Penalty
    ;   Problems = [problem(_, _, Why) | _],
        Score = none
    ),
    Result = result(Feasible, Why, RoomsNeeded, BySize, Penalty, Score, Report).

%! apply_option(+Option) is det.
%  Make the option the loaded setup (no restore), with its timetable.
apply_option(Option) :-
    install_option(Option),
    user:evaluate(_).


% ---------------------------------------------------------------------------
% Installing and restoring the resources
% ---------------------------------------------------------------------------

save_setup(setup(Sessions, Rooms, Seats, Exams, AccCols)) :-
    findall(session_time(S, D, St, En), user:session_time(S, D, St, En), Sessions),
    findall(room(R, Ro, Co, A), user:room(R, Ro, Co, A), Rooms),
    findall(seat(R, Ro, Co, T), user:seat(R, Ro, Co, T), Seats),
    findall(exam(C, S), user:exam(C, S), Exams),
    accessible_columns(Seats, AccCols).

restore_setup(setup(Sessions, Rooms, Seats, Exams, _)) :-
    clear_resources,
    forall(member(F, Sessions), assertz(user:F)),
    forall(member(F, Rooms), assertz(user:F)),
    forall(member(F, Seats), assertz(user:F)),
    forall(member(F, Exams), assertz(user:F)),
    allocation:forget_allocations.

clear_resources :-
    retractall(user:session_time(_, _, _, _)),
    retractall(user:room(_, _, _, _)),
    retractall(user:seat(_, _, _, _)),
    retractall(user:exam(_, _)),
    allocation:forget_allocations.

%! accessible_columns(+Seats, -Cols) is det.
%  The front-row columns that are accessible in the loaded rooms, so the
%  rooms the planner builds have accessible seats in the same places.
accessible_columns(Seats, Cols) :-
    findall(C, member(seat(_, 1, C, accessible), Seats), Cs0),
    sort(Cs0, Cs),
    ( Cs == [] -> Cols = [1, 3, 5, 7] ; Cols = Cs ).

install_option(option(Days, Slots, Start, Pool)) :-
    save_setup(setup(_, _, Seats, _, _)),
    accessible_columns(Seats, AccCols),
    clear_resources,
    weekdays(Start, Days, Dates),
    install_sessions(Dates, Slots),
    install_rooms(Pool, AccCols).

install_sessions(Dates, Slots) :-
    findall(D-(St-En), ( member(D, Dates), member(St-En, Slots) ), Pairs),
    forall(nth1(I, Pairs, D-(St-En)),
           ( atom_concat(sess, I, S),
             assertz(user:session_time(S, D, St, En)) )).

%  Largest rooms first, numbered r101, r102, ...
install_rooms(Pool, AccCols) :-
    findall(Seats-pool(R, C, N), ( member(pool(R, C, N), Pool), Seats is R * C ), Keyed),
    sort(1, @>=, Keyed, Sorted),
    findall(R-C, ( member(_-pool(R, C, N), Sorted), between(1, N, _) ), Rooms),
    forall(nth1(I, Rooms, Rows-Cols),
           ( Num is 100 + I, atom_concat(r, Num, Id),
             assertz(user:room(Id, Rows, Cols, yes)),
             forall(( between(1, Rows, Row), between(1, Cols, Col) ),
                    ( ( Row =:= 1, memberchk(Col, AccCols) -> T = accessible ; T = normal ),
                      assertz(user:seat(Id, Row, Col, T)) )) )).


% ---------------------------------------------------------------------------
% Weekdays
% ---------------------------------------------------------------------------

%! weekdays(+StartDate, +N, -Dates) is det.
%  The first N weekdays from StartDate ('2026-12-01'), weekends skipped -
%  the same rule as generate_data.py.
weekdays(Start, N, Dates) :-
    atomic_list_concat([Ya, Ma, Da], '-', Start),
    atom_number(Ya, Y), atom_number(Ma, M), atom_number(Da, D),
    date_time_stamp(date(Y, M, D, 12, 0, 0, 0, -, -), T0),
    collect_weekdays(T0, N, Dates).

collect_weekdays(_, 0, []) :- !.
collect_weekdays(T, N, Dates) :-
    stamp_date_time(T, date(Y, M, D, _, _, _, _, _, _), local),
    day_of_the_week(date(Y, M, D), W),
    T1 is T + 86400,
    (   W =< 5
    ->  format_time(atom(A), '%F', T),
        Dates = [A | Rest],
        N1 is N - 1
    ;   Dates = Rest,
        N1 = N
    ),
    collect_weekdays(T1, N1, Rest).
