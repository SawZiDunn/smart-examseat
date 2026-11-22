% ===========================================================================
% allocation.pl  -  Stage 1: who goes to which room            (Member A)
% ===========================================================================
% Input : a session + the admin's filters.
% Output: Allocation = [room_group(RoomId, [s(StudentId, ExamCode), ...]), ...]
%
% This file never picks a seat - that is Member B's solver. It only decides
% the room split, and it does so conservatively enough that the solver is
% (almost) always able to finish. When the solver does fail it calls back
% into reallocate/4 with a reason, and we shuffle students out of the room
% that broke.
% ===========================================================================

:- module(allocation, [
        students_in_session/3,
        exam_clash/2,
        allocate_rooms/3,
        students_for_room/3,
        reallocate/4,
        reallocate_with_extra_room/4,
        forget_allocations/0,
        list_sessions/1,
        list_majors/1,
        list_years/1,
        list_rooms/1,
        room_layout/4,
        session_info/4,
        student_display/4,
        exams_in_session/2
   ]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(rules).

%! last_allocation(?Session, ?Allocation)
%  Remembers the most recent allocation per session so that
%  students_for_room/3 and reallocate/4 can read it back.
:- dynamic last_allocation/2.

%! forget_allocations is det.
%  Drops the cached allocations; called when the dataset is reloaded.
forget_allocations :- retractall(last_allocation(_, _)).

% ===========================================================================
% 1. Selecting the students for a session
% ===========================================================================

%! students_in_session(+Session, +Filters, -Students) is det.
%  Students = [s(StudentId, ExamCode), ...] sorted by student id.
%  Every student sitting an exam in Session who passes the filters.
students_in_session(Session, Filters, Students) :-
    findall(s(StudentId, Code),
            ( user:exam(Code, Session),
              user:enrolled(StudentId, Code),
              rules:matches_filters(StudentId, Filters) ),
            Raw),
    sort(Raw, Students).

%! exams_in_session(+Session, -Codes) is det.
exams_in_session(Session, Codes) :-
    findall(Code, user:exam(Code, Session), Raw),
    sort(Raw, Codes).

%! exam_clash(?StudentId, ?Session) is nondet.
%  True when a student is enrolled in two different exams held in the same
%  session. The dataset should contain none of these; the validator and the
%  data self-test both use this.
exam_clash(StudentId, Session) :-
    user:enrolled(StudentId, CodeA),
    user:exam(CodeA, Session),
    user:enrolled(StudentId, CodeB),
    user:exam(CodeB, Session),
    CodeA @< CodeB.


% ===========================================================================
% 2. Room allocation
% ===========================================================================

%! allocate_rooms(+Session, +Students, -Allocation) is det.
%
%  Strategy:
%    1. open the fewest (largest-first) available rooms that can plausibly
%       hold everyone - capacity, accessible seats, and the per-exam row
%       limit implied by the separation rule;
%    2. keep each exam/major/year cohort contiguous in the student order;
%    3. choose eligible rooms by cohort fit, using a tight fit as the final
%       tie-breaker to preserve room capacity for larger groups.
allocate_rooms(Session, Students, Allocation) :-
    open_rooms(Students, Rooms),
    order_students(Students, Ordered),
    empty_rooms(Rooms, Slots0),
    deal(Ordered, Slots0, Slots1, Unplaced),
    % Never drop a student. Anyone the rooms cannot take goes into the
    % biggest room anyway, so the solver reports the precise capacity,
    % feasibility, or search-limit reason for reallocation.
    overflow_into_first(Unplaced, Slots1, Slots),
    slots_to_allocation(Slots, Allocation),
    retractall(last_allocation(Session, _)),
    assertz(last_allocation(Session, Allocation)),
    !.                         % allocation is deterministic

%! students_for_room(+Session, +RoomId, -Students) is semidet.
students_for_room(Session, RoomId, Students) :-
    last_allocation(Session, Allocation),
    memberchk(room_group(RoomId, Students), Allocation).


% --- 2a. which rooms to open ----------------------------------------------

%! open_rooms(+Students, -Rooms) is det.
%  Rooms = [room_slot_spec(RoomId, Cap, AccessCap, MaxSameExam), ...]
open_rooms(Students, Rooms) :-
    findall(Cap-spec(RoomId, Cap, ACap, MaxE),
            ( rules:available_room(RoomId, _, _),
              rules:room_capacity(RoomId, Cap),
              rules:room_accessible_capacity(RoomId, ACap),
              rules:max_same_exam_per_room(RoomId, MaxE) ),
            Pairs),
    sort(1, @>=, Pairs, Sorted),            % biggest rooms first
    pairs_values(Sorted, All),
    demand(Students, Total, AccessNeeded, ExamCounts),
    grow_prefix(All, Total, AccessNeeded, ExamCounts, [], Rooms0),
    (   Rooms0 == [] -> Rooms = All ; Rooms = Rooms0 ).

%! demand(+Students, -Total, -AccessNeeded, -ExamCounts) is det.
demand(Students, Total, AccessNeeded, ExamCounts) :-
    length(Students, Total),
    include(access_student, Students, AccessList),
    length(AccessList, AccessNeeded),
    findall(Code, member(s(_, Code), Students), Codes),
    msort(Codes, SortedCodes),
    count_runs(SortedCodes, ExamCounts).

access_student(s(StudentId, _)) :- rules:needs_accessible(StudentId).

count_runs([], []).
count_runs([X | Xs], [X-N | Rest]) :-
    take_same(X, Xs, 1, N, Tail),
    count_runs(Tail, Rest).

take_same(X, [X | Xs], N0, N, Tail) :- !,
    N1 is N0 + 1,
    take_same(X, Xs, N1, N, Tail).
take_same(_, Xs, N, N, Xs).

%! grow_prefix(+AllRooms, +Total, +AccessNeeded, +ExamCounts, +Acc, -Chosen)
%  Adds rooms largest-first until the opened set can hold the cohort.
grow_prefix([], _, _, _, Acc, Chosen) :-
    reverse(Acc, Chosen).
grow_prefix([Room | Rest], Total, AccessNeeded, ExamCounts, Acc, Chosen) :-
    Acc1 = [Room | Acc],
    (   enough(Acc1, Total, AccessNeeded, ExamCounts)
    ->  reverse(Acc1, Chosen)
    ;   grow_prefix(Rest, Total, AccessNeeded, ExamCounts, Acc1, Chosen)
    ).

enough(Rooms, Total, AccessNeeded, ExamCounts) :-
    sum_field(Rooms, 2, Cap),
    sum_field(Rooms, 3, ACap),
    sum_field(Rooms, 4, MaxE),
    Cap >= Total,
    ACap >= AccessNeeded,
    forall(member(_-N, ExamCounts), MaxE >= N).

sum_field(Rooms, Arg, Sum) :-
    findall(V, ( member(R, Rooms), arg(Arg, R, V) ), Vs),
    sum_list(Vs, Sum).


% --- 2b. ordering the students --------------------------------------------

%! order_students(+Students, -Ordered) is det.
%  Accessible students come first. Within each access group, keep students
%  from the same exam, major, and year together for room placement.
order_students(Students, Ordered) :-
    partition(access_student, Students, Access, Normal),
    cohort_groups(Access, AccessGroups),
    cohort_groups(Normal, NormalGroups),
    append(AccessGroups, AccessOrdered),
    append(NormalGroups, NormalOrdered),
    append(AccessOrdered, NormalOrdered, Ordered).

cohort_key(s(StudentId, Code), cohort(Code, Major, Year)) :-
    rules:student_major(StudentId, Major),
    rules:student_year(StudentId, Year).

%! cohort_groups(+Students, -Groups) is det.
%  Groups are ordered largest-first; each group is one exam/major/year cohort.
cohort_groups(Students, Groups) :-
    map_key(cohort_key, Students, Keyed),
    keysort(Keyed, SortedKeyed),
    group_pairs_by_key(SortedKeyed, Grouped),
    pairs_values(Grouped, Cohorts),
    map_len(Cohorts, Sized),
    sort(1, @>=, Sized, LargestFirst),
    pairs_values(LargestFirst, Groups).

map_key(_, [], []).
map_key(KeyPred, [X | Xs], [K-X | Ys]) :-
    call(KeyPred, X, K),
    map_key(KeyPred, Xs, Ys).

map_len([], []).
map_len([L | Ls], [N-L | T]) :-
    length(L, N),
    map_len(Ls, T).


% --- 2c. dealing students into rooms --------------------------------------
%
% A room under construction is held as
%     slot(RoomId, FreeTotal, FreeAccess, MaxSameExam, ExamCounts, Students)
% ExamCounts is a Code-Count pair list, Students is built in reverse.

empty_rooms([], []).
empty_rooms([spec(RoomId, Cap, ACap, MaxE) | Rest],
            [slot(RoomId, Cap, ACap, MaxE, [], []) | Slots]) :-
    empty_rooms(Rest, Slots).

%! deal(+Students, +Slots0, -Slots, -Unplaced) is det.
deal([], Slots, Slots, []).
deal([S | Rest], Slots0, Slots, Unplaced) :-
    cohort_demand(S, [S | Rest], CohortSize, CohortAccess),
    (   place(S, CohortSize, CohortAccess, Slots0, Slots1)
    ->  deal(Rest, Slots1, Slots, Unplaced)
    ;   deal(Rest, Slots0, Slots, Unplaced0),
        Unplaced = [S | Unplaced0]
    ).

%! place(+Student, +CohortSize, +CohortAccess, +Slots0, -Slots) is semidet.
%  Prefer the room that can keep the largest part of the student's cohort
%  together. Among equally good rooms, use the tightest fit.
place(Student, CohortSize, CohortAccess, Slots0, Slots) :-
    Student = s(StudentId, _),
    (   rules:needs_accessible(StudentId) -> Access = yes ; Access = no ),
    best_slot(Slots0, Access, Student, CohortSize, CohortAccess, Best),
    Best = slot(RoomId, _, _, _, _, _),
    add_to_slot(RoomId, Student, Access, Slots0, Slots).

cohort_demand(Student, Remaining, Total, Accessible) :-
    cohort_key(Student, Key),
    include(in_cohort(Key), Remaining, Members),
    length(Members, Total),
    include(access_student, Members, AccessibleMembers),
    length(AccessibleMembers, Accessible).

in_cohort(Key, Student) :-
    cohort_key(Student, Key).

best_slot(Slots, Access, Student, CohortSize, CohortAccess, Best) :-
    Student = s(_, Code),
    include(can_take(Access, Code), Slots, Candidates),
    Candidates = [First | _],
    cohort_key(Student, Key),
    foldl(better_cohort_slot(Key, Code, CohortSize, CohortAccess),
          Candidates, First, Best).

can_take(Access, Code, slot(_, Free, FreeA, MaxE, Counts, _)) :-
    Free > 0,
    ( Access == yes -> FreeA > 0 ; true ),
    ( memberchk(Code-N, Counts) -> N < MaxE ; true ).

better_cohort_slot(Key, Code, CohortSize, CohortAccess,
                   Candidate, Current, Best) :-
    slot_cohort_score(Key, Code, CohortSize, CohortAccess,
                      Candidate, CandidateScore),
    slot_cohort_score(Key, Code, CohortSize, CohortAccess,
                      Current, CurrentScore),
    ( CandidateScore @> CurrentScore
    -> Best = Candidate
    ;  Best = Current
    ).

% Scores are compared lexicographically: keep more cohort members together,
% retain existing cohort members, fit the remaining block, then use a tighter
% room fit to leave larger rooms for larger groups.
slot_cohort_score(Key, Code, CohortSize, CohortAccess,
                  slot(_, Free, FreeA, MaxE, Counts, Students),
                  score(Together, Existing, WholeFit, Potential,
                        NegAvailable)) :-
    count_cohort(Key, Students, Existing),
    ( memberchk(Code-ExamCount, Counts) -> true ; ExamCount = 0 ),
    ExamRoomFree is MaxE - ExamCount,
    Available is min(Free, ExamRoomFree),
    AccessibleFit is min(CohortAccess, min(FreeA, Available)),
    NormalSize is CohortSize - CohortAccess,
    NormalFit is min(NormalSize, Available - AccessibleFit),
    Potential is AccessibleFit + NormalFit,
    Together is Existing + Potential,
    ( Potential =:= CohortSize -> WholeFit = 1 ; WholeFit = 0 ),
    NegAvailable is -Available.

count_cohort(Key, Students, Count) :-
    include(in_cohort(Key), Students, Cohort),
    length(Cohort, Count).

add_to_slot(RoomId, S, Access,
            [slot(RoomId, Free, FreeA, MaxE, Counts, Students) | Rest],
            [slot(RoomId, Free1, FreeA1, MaxE, Counts1, [S | Students]) | Rest]) :-
    !,
    Free1 is Free - 1,
    ( Access == yes -> FreeA1 is FreeA - 1 ; FreeA1 = FreeA ),
    S = s(_, Code),
    bump(Code, Counts, Counts1).
add_to_slot(RoomId, S, Access, [Other | Rest], [Other | Rest1]) :-
    add_to_slot(RoomId, S, Access, Rest, Rest1).

bump(Code, [], [Code-1]).
bump(Code, [Code-N | T], [Code-N1 | T]) :- !, N1 is N + 1.
bump(Code, [P | T], [P | T1]) :- bump(Code, T, T1).

%! slots_to_allocation(+Slots, -Allocation) is det.
%  Drops rooms that ended up empty and restores student order.
%! overflow_into_first(+Unplaced, +Slots0, -Slots) is det.
%  Slots are biggest-first, so the overflow lands in the largest room.
overflow_into_first([], Slots, Slots) :- !.
overflow_into_first(Unplaced, [slot(R, F, FA, M, C, Rev) | Rest],
                    [slot(R, F, FA, M, C, Rev1) | Rest]) :-
    reverse(Unplaced, RevUnplaced),
    append(RevUnplaced, Rev, Rev1).

slots_to_allocation([], []).
slots_to_allocation([slot(_, _, _, _, _, []) | Rest], Allocation) :- !,
    slots_to_allocation(Rest, Allocation).
slots_to_allocation([slot(RoomId, _, _, _, _, Rev) | Rest],
                    [room_group(RoomId, Students) | Allocation]) :-
    reverse(Rev, Students),
    slots_to_allocation(Rest, Allocation).


% ===========================================================================
% 3. Reallocation after a solver failure
% ===========================================================================

%! reallocate(+Session, +FailedRoomId, +Reason, -NewAllocation) is semidet.
%
%  Moves students out of the room the solver could not satisfy and spreads
%  them to other rooms with available capacity before opening an unused room.
%
%  Fails when nothing can be moved - that is the signal for generate_seating/3
%  to give up rather than loop.
reallocate(Session, FailedRoomId, Reason, NewAllocation) :-
    last_allocation(Session, Allocation),
    select(room_group(FailedRoomId, Students), Allocation, OtherGroups),
    length(Students, Count),
    offload_count(Reason, Count, Students, ToMove),
    ToMove > 0,
    pick_victims(Reason, Students, ToMove, Victims, Keepers),
    Victims \== [],
    rebuild_slots(OtherGroups, FailedRoomId, Slots0),
    reallocate_victims(Reason, FailedRoomId, Victims, Slots0, Slots2),
    finish_reallocation(Session, FailedRoomId, Keepers, Slots2, NewAllocation).

%! reallocate_with_extra_room(+Session, +FailedRoomId, +Reason, -NewAllocation)
%  Final fallback after capacity-first retries have not resolved the failure.
reallocate_with_extra_room(Session, FailedRoomId, Reason, NewAllocation) :-
    last_allocation(Session, Allocation),
    select(room_group(FailedRoomId, Students), Allocation, OtherGroups),
    length(Students, Count),
    offload_count(Reason, Count, Students, ToMove),
    ToMove > 0,
    pick_victims(Reason, Students, ToMove, Victims, Keepers),
    Victims \== [],
    rebuild_slots(OtherGroups, FailedRoomId, Slots0),
    open_extra_room(FailedRoomId, Slots0, [Extra | _]),
    deal(Victims, [Extra], [ExtraPlaced], UnplacedExtra),
    deal(UnplacedExtra, Slots0, OtherSlots, Unplaced),
    append([ExtraPlaced], OtherSlots, Slots1),
    deal_overflow(Unplaced, FailedRoomId, Slots1, Slots2),
    finish_reallocation(Session, FailedRoomId, Keepers, Slots2, NewAllocation).

finish_reallocation(Session, FailedRoomId, Keepers, Slots, NewAllocation) :-
    slots_to_allocation(Slots, Rest),
    (   Keepers == []
    ->  NewAllocation = Rest
    ;   NewAllocation = [room_group(FailedRoomId, Keepers) | Rest]
    ),
    retractall(last_allocation(Session, _)),
    assertz(last_allocation(Session, NewAllocation)),
    !.

reallocate_victims(_, FailedRoomId, Victims, Slots0, Slots) :-
    deal(Victims, Slots0, Slots1, Unplaced),
    deal_overflow(Unplaced, FailedRoomId, Slots1, Slots).

deal_overflow([], _, Slots, Slots) :- !.
deal_overflow(Unplaced, FailedRoomId, Slots0, Slots) :-
    open_extra_room(FailedRoomId, Slots0, Slots1),
    deal(Unplaced, Slots1, Slots, []).

%! offload_count(+Reason, +Count, +Students, -ToMove) is det.
offload_count(not_enough_seats(_, Needed, Have), _, _, ToMove) :- !,
    ToMove is max(1, Needed - Have).
offload_count(not_enough_accessible(_, Needed, Have), _, _, ToMove) :- !,
    ToMove is max(1, Needed - Have).
offload_count(no_solution(_), Count, _, ToMove) :- !,
    ToMove is max(1, (Count + 2) // 3).
offload_count(search_limit(_), Count, _, ToMove) :- !,
    % A smaller group reduces search complexity without assuming the room is
    % impossible or immediately consuming another room.
    ToMove is max(1, (Count + 2) // 3).
offload_count(_, Count, _, ToMove) :-
    ToMove is max(1, (Count + 4) // 5).

%! pick_victims(+Reason, +Students, +N, -Victims, -Keepers) is det.
%  For an accessibility failure, move accessible students. Otherwise move
%  students from the largest exam group, since that is what the separation
%  rule is choking on.
pick_victims(not_enough_accessible(_, _, _), Students, N, Victims, Keepers) :- !,
    include(access_student, Students, Access),
    exclude(access_student, Students, Normal),
    split_at(N, Access, Victims, AccessKeep),
    append(AccessKeep, Normal, Keepers).
pick_victims(_, Students, N, Victims, Keepers) :-
    largest_exam(Students, Code),
    include(of_exam(Code), Students, Group),
    exclude(access_student, Group, Movable),
    split_at(N, Movable, Victims0, _),
    (   Victims0 \== []
    ->  Victims = Victims0
    ;   % the biggest exam group is entirely accessible students: fall back
        % to moving anyone who is movable at all
        exclude(access_student, Students, AnyMovable),
        split_at(N, AnyMovable, Victims, _)
    ),
    subtract_eq(Students, Victims, Keepers).

of_exam(Code, s(_, Code)).

largest_exam(Students, Code) :-
    findall(C, member(s(_, C), Students), Codes),
    msort(Codes, Sorted),
    count_runs(Sorted, Counts),
    transpose_pairs_max(Counts, Code).

transpose_pairs_max([C-N | Rest], Code) :-
    foldl(max_pair, Rest, C-N, Code-_).

max_pair(C-N, _-BN, Best) :- N > BN, !, Best = C-N.
max_pair(_, Acc, Acc).

split_at(0, Rest, [], Rest) :- !.
split_at(_, [], [], []) :- !.
split_at(N, [X | Xs], [X | Ys], Rest) :-
    N1 is N - 1,
    split_at(N1, Xs, Ys, Rest).

subtract_eq([], _, []).
subtract_eq([X | Xs], Rem, Out) :-
    (   select_eq(X, Rem, Rem1)
    ->  Out = Out1
    ;   Rem1 = Rem, Out = [X | Out1]
    ),
    subtract_eq(Xs, Rem1, Out1).

select_eq(X, [Y | T], T)       :- X == Y, !.
select_eq(X, [Y | T], [Y | T1]) :- select_eq(X, T, T1).

%! rebuild_slots(+Groups, +ExcludeRoom, -Slots) is det.
%  Turns the surviving room groups back into fillable slots.
rebuild_slots(Groups, _Exclude, Slots) :-
    findall(Slot,
            ( member(room_group(RoomId, Students), Groups),
              group_to_slot(RoomId, Students, Slot) ),
            Slots).

group_to_slot(RoomId, Students, slot(RoomId, Free, FreeA, MaxE, Counts, Rev)) :-
    rules:room_capacity(RoomId, Cap),
    rules:room_accessible_capacity(RoomId, ACap),
    rules:max_same_exam_per_room(RoomId, MaxE),
    length(Students, Used),
    include(access_student, Students, AccessUsed),
    length(AccessUsed, UsedA),
    Free is Cap - Used,
    FreeA is ACap - UsedA,
    findall(C, member(s(_, C), Students), Codes),
    msort(Codes, Sorted),
    count_runs(Sorted, Counts),
    reverse(Students, Rev).

%! open_extra_room(+FailedRoomId, +Slots0, -Slots) is semidet.
%  Brings the largest still-unused available room online. The room that just
%  failed is not in Slots0 but still holds its keepers, so it is never
%  re-opened (that would put the same room in the plan twice).
open_extra_room(FailedRoomId, Slots0,
                [slot(RoomId, Cap, ACap, MaxE, [], []) | Slots0]) :-
    findall(Cap0-RoomId0,
            ( rules:available_room(RoomId0, _, _),
              RoomId0 \== FailedRoomId,
              \+ memberchk(slot(RoomId0, _, _, _, _, _), Slots0),
              rules:room_capacity(RoomId0, Cap0) ),
            Pairs),
    Pairs \== [],
    sort(1, @>=, Pairs, [Cap-RoomId | _]),
    rules:room_accessible_capacity(RoomId, ACap),
    rules:max_same_exam_per_room(RoomId, MaxE).


% ===========================================================================
% 4. Helper predicates for the UI (README.md section 8.4)
% ===========================================================================

%! list_sessions(-Sessions) is det.
list_sessions(Sessions) :-
    findall(S, user:session_time(S, _, _, _), Raw),
    sort_sessions(Raw, Sessions).

%  sess2 must come before sess10, so sort on the numeric suffix.
sort_sessions(Raw, Sessions) :-
    findall(N-S,
            ( member(S, Raw),
              atom_concat(sess, Suffix, S),
              atom_number(Suffix, N) ),
            Pairs0),
    (   length(Pairs0, L), length(Raw, L)
    ->  keysort(Pairs0, Sorted), pairs_values(Sorted, Sessions)
    ;   sort(Raw, Sessions)
    ).

%! list_majors(-Majors) is det.
list_majors(Majors) :-
    findall(M, user:student(_, M, _, _), Raw),
    sort(Raw, Majors).

%! list_years(-Years) is det.
list_years(Years) :-
    findall(Y, user:student(_, _, Y, _), Raw),
    sort(Raw, Years).

%! list_rooms(-Rooms) is det.
%  Rooms = [room(RoomId, Rows, Cols, Available), ...]
list_rooms(Rooms) :-
    findall(room(RoomId, Rows, Cols, Avail),
            user:room(RoomId, Rows, Cols, Avail),
            Rooms).

%! room_layout(+RoomId, -Rows, -Cols, -Seats) is semidet.
%  Seats = [seat(Row, Col, SeatType), ...]
room_layout(RoomId, Rows, Cols, Seats) :-
    user:room(RoomId, Rows, Cols, _),
    rules:room_seats(RoomId, Seats).

%! session_info(+Session, -Date, -Start, -End) is semidet.
session_info(Session, Date, Start, End) :-
    user:session_time(Session, Date, Start, End).

%! student_display(+StudentId, -Name, -Major, -Year) is semidet.
student_display(StudentId, Name, Major, Year) :-
    user:student(StudentId, Major, Year, _),
    ( user:student_name(StudentId, Name) -> true ; Name = StudentId ).
