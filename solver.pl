% ===========================================================================
% solver.pl  -  Stage 2: the seat CSP for ONE room             (Member B)
% ===========================================================================
% CSP model
%   Variables : the students allocated to this room
%   Domains   : the seats of this room
%   Constraints:
%       always   one_seat_per_student, seat_unique, room_capacity
%       active   whatever constraints.pl holds: separation(N), column_gap(N),
%                no_diagonal, different_major_neighbours, accessible_seats,
%                room_fill(P), custom seat rules written in Prolog.
%                Hard ones prune the search; soft ones order the seats.
%
% Search: depth-first backtracking over students, with
%   - variable ordering  : most constrained student first
%   - value ordering     : earliest remaining seat in column-major order
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
:- use_module(library(aggregate)).
:- use_module(rules).
:- use_module(constraints, []).
:- use_module(custom_rules, []).

%! inference_budget(+NStudents, -Limit) is det.
%  Backtracking is exponential in the worst case. Rather than hang on an
%  difficult room we bound the work and report search_limit/1 separately from
%  a proven no_solution/1.
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
%           | search_limit(RoomId)
%           | search_error(RoomId)
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
    rules:usable_capacity(RoomId, Have),             % all seats, or room_fill(P)
    (   Needed > Have
    ->  Problem = not_enough_seats(RoomId, Needed, Have)
    ;   include(needs_access, Students, AccessList),
        length(AccessList, NeedA),
        rules:room_accessible_capacity(RoomId, HaveA),
        NeedA > HaveA,
        Problem = not_enough_accessible(RoomId, NeedA, HaveA)
    ;   exam_exceeds_room_limit(RoomId, Students)
    ->  Problem = no_solution(RoomId)
    ).

needs_access(s(StudentId, _)) :- rules:requires_accessible_seat(StudentId).

exam_exceeds_room_limit(RoomId, Students) :-
    rules:max_same_exam_per_room(RoomId, Limit),
    findall(Code, member(s(_, Code), Students), Codes),
    sort(Codes, UniqueCodes),
    member(Code, UniqueCodes),
    aggregate_all(count, member(s(_, Code), Students), Count),
    Count > Limit,
    !.


% ---------------------------------------------------------------------------
% The search
% ---------------------------------------------------------------------------

search(RoomId, Students, Result, Options) :-
    rules:room_seats(RoomId, AllSeats),
    include(is_accessible_seat, AllSeats, AccessSeats),
    order_students(Students, Ordered),
    length(Students, N),
    ( memberchk(budget(B), Options) -> Limit = B ; inference_budget(N, Limit) ),
    % Which optional rules are active right now (constraints.pl). They are
    % read once per room, not once per seat.
    constraints:seat_rules(HardRules, SoftRules),
    constraints:custom_ids(seat, hard, CustomIds),
    (   constraints:accessible_rule(soft(AW)) -> SoftAll = [accessible_seats-AW | SoftRules]
    ;   SoftAll = SoftRules
    ),
    rules:min_separation(Sep),
    Need is Sep + 1,
    Ctx = ctx(RoomId, AccessSeats, AllSeats, HardRules, SoftAll, CustomIds, Need),
    search_with_budget(RoomId, Ordered, Ctx, Limit, Result).

search_with_budget(RoomId, Ordered, Ctx, Limit, Result) :-
    empty_assoc(Used0),
    empty_assoc(Rows0),
    (   catch(
            call_with_inference_limit(
                assign(Ordered, Ctx, Used0, Rows0, [], Rev),
                Limit, Outcome),
            _Error, (Outcome = exception, Rev = []))
    ->  (   Outcome == inference_limit_exceeded
        ->  Result = failed(search_limit(RoomId))
        ;   Outcome == exception
        ->  Result = failed(search_error(RoomId))
        ;   reverse(Rev, Assignments),
            Result = ok(Assignments)
        )
    ;   Result = failed(no_solution(RoomId))
    ).

is_accessible_seat(seat(_, _, accessible)).

%! assign(+Students, +Ctx, +UsedSeats, +ExamRowCols, +Acc, -Assignments)
%! is nondet.
%
%  This is the backtracking core. Each recursive step picks one seat for the
%  head student with member/2; if a later student cannot be placed, Prolog
%  backtracks into that member/2 and tries the next seat automatically.
%
%  Used maps Row-Col to p(Student, Exam) so neighbour rules can look around
%  a seat. Every hard rule in the constraint knowledge base is checked right
%  after the seat is chosen; soft rules only change the ORDER in which seats
%  are tried (cheapest first).
assign([], _, _, _, Acc, Acc).
assign([s(StudentId, Code) | Rest], Ctx, Used, Rows, Acc, Out) :-
    Ctx = ctx(RoomId, _, _, Hard, _, CustomIds, Need),
    candidate_seats(StudentId, Code, Ctx, Used, Seats),
    member(seat(Row, Col, Type), Seats),
    \+ get_assoc(Row-Col, Used, _),                      % seat_unique
    rules:seat_fits(StudentId, Type),                    % accessibility
    exam_row_cols(Code, Row, Rows, Cols),
    far_enough(Cols, Col, Need),                         % separation
    \+ ( member(Rule, Hard),                             % other hard rules
          constraints:seat_conflict(Rule, StudentId, Code, Row, Col, Used) ),
    New = assign(StudentId, Code, RoomId, Row, Col),
    custom_rules:seat_rules_ok(CustomIds, [New | Acc]),  % rules typed in Prolog
    put_assoc(Row-Col, Used, p(StudentId, Code), Used1),
    put_assoc(Code-Row, Rows, [Col | Cols], Rows1),
    assign(Rest, Ctx, Used1, Rows1, [New | Acc], Out).

%! candidate_seats(+Student, +Code, +Ctx, +Used, -Seats) is det.
%  The domain, in the order to try it: column-first, or cheapest-first by
%  soft-constraint penalty when soft seat rules are active (a stable sort, so
%  equal-cost seats keep the column-first order).
candidate_seats(StudentId, _, ctx(_, AccessSeats, AllSeats, _, [], _, _), _, Seats) :- !,
    domain(StudentId, AccessSeats, AllSeats, Seats).
candidate_seats(StudentId, Code, ctx(_, AccessSeats, AllSeats, _, Soft, _, _), Used, Seats) :-
    domain(StudentId, AccessSeats, AllSeats, Domain),
    findall(Cost-seat(Row, Col, Type),
            ( member(seat(Row, Col, Type), Domain),
              \+ get_assoc(Row-Col, Used, _),
              soft_cost(Soft, StudentId, Code, Row, Col, Type, Used, Cost) ),
            Keyed),
    keysort(Keyed, Sorted),
    pairs_values(Sorted, Seats).

soft_cost(Soft, StudentId, Code, Row, Col, Type, Used, Cost) :-
    foldl(add_soft(StudentId, Code, Row, Col, Type, Used), Soft, 0, Cost).

add_soft(StudentId, _, _, _, Type, _, accessible_seats-W, C0, C) :- !,
    (   rules:needs_accessible(StudentId), Type \== accessible
    ->  C is C0 + W ; C = C0 ).
add_soft(StudentId, Code, Row, Col, _, Used, Rule-W, C0, C) :-
    aggregate_all(count,
                  constraints:seat_conflict(Rule, StudentId, Code, Row, Col, Used), N),
    C is C0 + N * W.

%! domain(+StudentId, +AccessSeats, +AllSeats, -Domain) is det.
%  A student who must have an accessible seat has only the accessible seats
%  in their domain. Everyone else can use the earliest remaining seat;
%  accessible-seat students are ordered first so their required seats are
%  assigned beforehand.
domain(StudentId, AccessSeats, AllSeats, Domain) :-
    (   rules:requires_accessible_seat(StudentId)
    ->  Domain = AccessSeats
    ;   Domain = AllSeats
    ).

%! far_enough(+OtherCols, +Col, +Need) is semidet.
%  The separation rule (rules:separation_ok/3) with the distance read once per
%  room: every same-exam column in this row is at least Need away.
far_enough([], _, _).
far_enough([C | Cs], Col, Need) :-
    abs(Col - C) >= Need,
    far_enough(Cs, Col, Need).

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
