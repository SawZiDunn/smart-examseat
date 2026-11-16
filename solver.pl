% ===========================================================================
% solver.pl  -  Stage 2: the seat CSP for ONE room             (Member B)
% ===========================================================================
% CSP model
%   Variables : the students allocated to this room
%   Domains   : the seats of this room
%   Constraints (all hard):
%       one_seat_per_student  - every student gets exactly one seat
%       seat_unique           - no seat is given to two students
%       room_capacity         - cannot seat more students than seats
%       accessibility         - Access \= none  =>  SeatType = accessible
%       separation            - two students of the SAME exam in the SAME row
%                               must be >= min_separation+1 columns apart
%
% Search: depth-first backtracking over students, with
%   - variable ordering  : most constrained student first
%   - value ordering     : row-major, and normal seats before accessible ones
%                          for students who do not need an accessible seat
%   - an inference limit so a hopeless room reports failure instead of hanging
% ===========================================================================

:- module(solver, [
        solve_room/4,
        solve_room/5
   ]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(assoc)).
:- use_module(rules).

%! inference_budget(+NStudents, -Limit) is det.
%  Backtracking is exponential in the worst case. Rather than hang on an
%  impossible room we bound the work and report no_solution/1, which lets
%  Member A's reallocate/4 move students out and try again.
inference_budget(N, Limit) :-
    Limit is 200_000 + N * 20_000.


% ===========================================================================
% solve_room/4
% ===========================================================================

%! solve_room(+Session, +RoomId, +Students, -Result) is det.
%
%  Students = [s(StudentId, ExamCode), ...]
%  Result   = ok([assign(StudentId, ExamCode, RoomId, Row, Col), ...])
%           | failed(Reason)
%
%  Reason   = not_enough_seats(RoomId, Needed, Have)
%           | not_enough_accessible(RoomId, Needed, Have)
%           | no_solution(RoomId)
solve_room(Session, RoomId, Students, Result) :-
    solve_room(Session, RoomId, Students, Result, []).

%! solve_room(+Session, +RoomId, +Students, -Result, +Options) is det.
%  Options: budget(N) to override the inference limit (used by the tests).
solve_room(_Session, RoomId, [], ok([]), _) :- !,
    ( rules:available_room(RoomId, _, _) -> true ; true ).
solve_room(_Session, RoomId, Students, Result, Options) :-
    (   \+ rules:available_room(RoomId, _, _)
    ->  Result = failed(no_solution(RoomId))
    ;   precheck(RoomId, Students, Problem)
    ->  Result = failed(Problem)
    ;   search(RoomId, Students, Result, Options)
    ).


% ---------------------------------------------------------------------------
% Cheap pre-checks: catch the two counting failures before searching at all.
% ---------------------------------------------------------------------------

precheck(RoomId, Students, Problem) :-
    length(Students, Needed),
    rules:room_capacity(RoomId, Have),
    (   Needed > Have
    ->  Problem = not_enough_seats(RoomId, Needed, Have)
    ;   include(needs_access, Students, AccessList),
        length(AccessList, NeedA),
        rules:room_accessible_capacity(RoomId, HaveA),
        NeedA > HaveA,
        Problem = not_enough_accessible(RoomId, NeedA, HaveA)
    ).

needs_access(s(StudentId, _)) :- rules:needs_accessible(StudentId).


% ---------------------------------------------------------------------------
% The search
% ---------------------------------------------------------------------------

search(RoomId, Students, Result, Options) :-
    rules:room_seats(RoomId, AllSeats),
    partition(is_accessible_seat, AllSeats, AccessSeats, NormalSeats),
    % value ordering: a student who does not need an accessible seat tries
    % the normal seats first, so the scarce accessible seats stay free.
    append(NormalSeats, AccessSeats, NormalFirst),
    order_students(Students, Ordered),
    length(Students, N),
    ( memberchk(budget(B), Options) -> Limit = B ; inference_budget(N, Limit) ),
    empty_assoc(Used0),
    empty_assoc(Rows0),
    (   catch(
            call_with_inference_limit(
                assign(Ordered, RoomId, AccessSeats, NormalFirst,
                       Used0, Rows0, [], Rev),
                Limit, Outcome),
            _Error, (Outcome = exception, Rev = []))
    ->  (   Outcome == inference_limit_exceeded
        ->  Result = failed(no_solution(RoomId))
        ;   Outcome == exception
        ->  Result = failed(no_solution(RoomId))
        ;   reverse(Rev, Assignments),
            Result = ok(Assignments)
        )
    ;   Result = failed(no_solution(RoomId))
    ).

is_accessible_seat(seat(_, _, accessible)).

%! assign(+Students, +RoomId, +AccessSeats, +NormalFirstSeats,
%!        +UsedSeats, +ExamRowCols, +Acc, -Assignments) is nondet.
%
%  This is the backtracking core. Each recursive step picks one seat for the
%  head student with member/2; if a later student cannot be placed, Prolog
%  backtracks into that member/2 and tries the next seat automatically.
assign([], _, _, _, _, _, Acc, Acc).
assign([s(StudentId, Code) | Rest], RoomId, AccessSeats, NormalFirst,
       Used, Rows, Acc, Out) :-
    domain(StudentId, AccessSeats, NormalFirst, Domain),
    member(seat(Row, Col, Type), Domain),
    \+ get_assoc(Row-Col, Used, _),                      % seat_unique
    rules:seat_fits(StudentId, Type),                    % accessibility
    exam_row_cols(Code, Row, Rows, Cols),
    rules:separation_ok(Row, Col, Cols),                 % separation
    put_assoc(Row-Col, Used, used, Used1),
    put_assoc(Code-Row, Rows, [Col | Cols], Rows1),
    assign(Rest, RoomId, AccessSeats, NormalFirst, Used1, Rows1,
           [assign(StudentId, Code, RoomId, Row, Col) | Acc], Out).

%! domain(+StudentId, +AccessSeats, +NormalFirst, -Domain) is det.
%  A student who needs accessibility has only the accessible seats in their
%  domain - that is what makes them "most constrained".
domain(StudentId, AccessSeats, NormalFirst, Domain) :-
    (   rules:needs_accessible(StudentId)
    ->  Domain = AccessSeats
    ;   Domain = NormalFirst
    ).

exam_row_cols(Code, Row, Rows, Cols) :-
    ( get_assoc(Code-Row, Rows, Cols0) -> Cols = Cols0 ; Cols = [] ).


% ---------------------------------------------------------------------------
% Variable ordering: most constrained student first
% ---------------------------------------------------------------------------

%! order_students(+Students, -Ordered) is det.
%
%  Rank 0: students who need an accessible seat   (tiny domain)
%  Rank 1: everyone else, grouped by exam with the LARGEST exam group first
%          (that group is the one the separation rule squeezes hardest), and
%          kept contiguous so its members can be laid out at columns
%          1, 3, 5, ... before the next exam fills the gaps.
order_students(Students, Ordered) :-
    partition(needs_access, Students, Access, Normal),
    exam_groups(Normal, Groups),
    append(Groups, NormalOrdered),
    append(Access, NormalOrdered, Ordered).

%! exam_groups(+Students, -Groups) is det.
%  Groups = list of student lists, biggest exam group first.
exam_groups(Students, Groups) :-
    map_pair(Students, Keyed),
    keysort(Keyed, Sorted),
    group_pairs_by_key(Sorted, Grouped),
    pairs_values(Grouped, Lists),
    map_len(Lists, Sized),
    sort(1, @>=, Sized, BySize),
    pairs_values(BySize, Groups).

map_pair([], []).
map_pair([s(Id, Code) | T], [Code-s(Id, Code) | T1]) :- map_pair(T, T1).

map_len([], []).
map_len([L | Ls], [N-L | T]) :- length(L, N), map_len(Ls, T).
