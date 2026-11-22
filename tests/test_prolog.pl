% ===========================================================================
% tests/test_prolog.pl  -  plunit suite for the whole Prolog pipeline
% ===========================================================================
% Run from the project root:
%     swipl -g run_tests -t halt tests/test_prolog.pl
% ===========================================================================

:- use_module(library(plunit)).
:- use_module(library(lists)).
:- use_module(library(apply)).

:- ensure_loaded('../main.pl').


% ===========================================================================
% A: the dataset itself
% ===========================================================================

:- begin_tests(dataset, [setup(use_full_data)]).

test(no_exam_clash) :-
    \+ exam_clash(_, _).

test(every_enrolment_has_a_subject) :-
    forall(user:enrolled(_, Code), user:subject(Code)).

test(every_subject_has_an_exam) :-
    forall(user:subject(Code), user:exam(Code, _)).

test(every_exam_has_a_session_time) :-
    forall(user:exam(_, Session), user:session_time(Session, _, _, _)).

test(seats_match_room_dimensions) :-
    forall(user:room(RoomId, Rows, Cols, _),
           ( aggregate_all(count, user:seat(RoomId, _, _, _), N),
             N =:= Rows * Cols )).

test(seat_coordinates_in_range) :-
    forall(user:seat(RoomId, Row, Col, _),
           ( user:room(RoomId, Rows, Cols, _),
             between(1, Rows, Row), between(1, Cols, Col) )).

test(every_student_has_a_name) :-
    forall(user:student(Id, _, _, _), user:student_name(Id, _)).

test(access_values_are_known) :-
    forall(user:student(_, _, _, A), memberchk(A, [none, wheelchair, other_accessible])).

test(enough_accessible_seats_for_every_session) :-
    forall(list_sessions_member(S),
           ( students_in_session(S, filters([], []), Students),
             include([s(Id,_)]>>needs_accessible(Id), Students, Access),
             length(Access, Need),
             aggregate_all(count,
                 ( user:room(R, _, _, yes), user:seat(R, _, _, accessible) ),
                 Have),
             Need =< Have )).

list_sessions_member(S) :- list_sessions(L), member(S, L).

:- end_tests(dataset).


% ===========================================================================
% A: students_in_session/3 and the filters
% ===========================================================================

:- begin_tests(selection, [setup(use_full_data)]).

test(no_filter_returns_everyone) :-
    students_in_session(sess1, filters([], []), All),
    findall(s(Id, C),
            ( user:exam(C, sess1), user:enrolled(Id, C) ), Raw),
    sort(Raw, Expected),
    All == Expected.

test(year_filter_only_returns_that_year) :-
    students_in_session(sess1, filters([1], []), Students),
    forall(member(s(Id, _), Students), user:student(Id, _, 1, _)).

test(major_filter_only_returns_those_majors) :-
    students_in_session(sess1, filters([], [se, cs]), Students),
    forall(member(s(Id, _), Students),
           ( user:student(Id, M, _, _), memberchk(M, [se, cs]) )).

test(filters_combine) :-
    students_in_session(sess3, filters([2], [se]), Students),
    forall(member(s(Id, _), Students), user:student(Id, se, 2, _)).

test(filtered_is_subset_of_unfiltered) :-
    students_in_session(sess2, filters([], []), All),
    students_in_session(sess2, filters([1, 2], [se]), Some),
    forall(member(X, Some), memberchk(X, All)).

test(unknown_year_gives_nothing) :-
    students_in_session(sess1, filters([9], []), []).

:- end_tests(selection).


% ===========================================================================
% A: allocate_rooms/3
% ===========================================================================

:- begin_tests(allocation, [setup(use_full_data)]).

allocation_for(Session, Students, Allocation) :-
    students_in_session(Session, filters([], []), Students),
    allocate_rooms(Session, Students, Allocation).

test(every_student_is_placed_exactly_once) :-
    allocation_for(sess4, Students, Allocation),
    findall(S, ( member(room_group(_, G), Allocation), member(S, G) ), Placed),
    msort(Placed, SortedPlaced),
    msort(Students, SortedStudents),
    SortedPlaced == SortedStudents.

test(no_room_exceeds_capacity) :-
    allocation_for(sess4, _, Allocation),
    forall(member(room_group(RoomId, G), Allocation),
           ( length(G, N), room_capacity(RoomId, Cap), N =< Cap )).

test(only_available_rooms_are_used) :-
    allocation_for(sess4, _, Allocation),
    forall(member(room_group(RoomId, _), Allocation),
           available_room(RoomId, _, _)).

test(accessible_students_fit_the_accessible_seats) :-
    allocation_for(sess4, _, Allocation),
    forall(member(room_group(RoomId, G), Allocation),
           ( include([s(Id,_)]>>needs_accessible(Id), G, Access),
             length(Access, N),
             room_accessible_capacity(RoomId, Cap),
             N =< Cap )).

test(same_exam_count_respects_the_row_limit) :-
    allocation_for(sess4, _, Allocation),
    forall(member(room_group(RoomId, G), Allocation),
           ( max_same_exam_per_room(RoomId, Limit),
             findall(C, member(s(_, C), G), Codes),
             msort(Codes, Sorted), clumped(Sorted, Counts),
             forall(member(_-N, Counts), N =< Limit) )).

test(opens_no_room_beyond_the_first_sufficient_prefix) :-
    allocation_for(sess4, Students, _),
    once(allocation:open_rooms(Students, Rooms)),
    allocation:demand(Students, Total, AccessNeeded, ExamCounts),
    append(Prefix, [_Last], Rooms),
    \+ allocation:enough(Prefix, Total, AccessNeeded, ExamCounts),
    !.

test(students_for_room_reads_back_the_allocation) :-
    allocation_for(sess4, _, Allocation),
    Allocation = [room_group(RoomId, Students) | _],
    students_for_room(sess4, RoomId, Readback),
    Readback == Students.

test(reallocate_moves_students_out_of_the_failed_room) :-
    allocation_for(sess4, _, Allocation),
    Allocation = [room_group(RoomId, Students) | _],
    length(Allocation, BeforeRooms),
    length(Students, Before),
    once(reallocate(sess4, RoomId, no_solution(RoomId), New)),
    length(New, AfterRooms),
    AfterRooms =< BeforeRooms,
    ( memberchk(room_group(RoomId, Kept), New) -> length(Kept, After) ; After = 0 ),
    After < Before.

test(reallocation_uses_open_capacity_before_opening_a_room) :-
    Slots0 = [slot(r102, 2, 0, 9, [], [])],
    allocation:reallocate_victims(
        no_solution(r101), r101, [s(s0001, cs101)], Slots0, Slots),
    Slots == [slot(r102, 1, 0, 9, [cs101-1], [s(s0001, cs101)])].

test(reallocate_keeps_everyone) :-
    allocation_for(sess4, Students, Allocation),
    Allocation = [room_group(RoomId, _) | _],
    once(reallocate(sess4, RoomId, no_solution(RoomId), New)),
    findall(S, ( member(room_group(_, G), New), member(S, G) ), Placed),
    msort(Placed, A), msort(Students, B),
    A == B.

:- end_tests(allocation).


:- begin_tests(cohort_allocation, [setup(use_sample_data)]).

test(cohort_stays_with_its_accessible_member_when_possible) :-
    Slots0 = [slot(r101, 20, 1, 12, [], []),
              slot(r102, 15, 0, 9, [], [])],
    allocation:deal([s(s0003, cs101), s(s0001, cs101)],
                    Slots0, Slots, []),
    memberchk(slot(r101, _, _, _, _, RoomStudents), Slots),
    memberchk(s(s0003, cs101), RoomStudents),
    memberchk(s(s0001, cs101), RoomStudents),
    memberchk(slot(r102, _, _, _, _, []), Slots).

test(cohort_splits_when_the_exam_room_limit_requires_it) :-
    Slots0 = [slot(r101, 20, 1, 1, [], []),
              slot(r102, 15, 0, 1, [], [])],
    allocation:deal([s(s0003, cs101), s(s0001, cs101)],
                    Slots0, Slots, []),
    memberchk(slot(r101, _, _, _, _, [s(s0003, cs101)]), Slots),
    memberchk(slot(r102, _, _, _, _, [s(s0001, cs101)]), Slots).

test(cohort_order_is_contiguous_after_accessible_students) :-
    Students = [s(s0001, cs101), s(s0003, cs101), s(s0005, cs101),
                s(s0002, ma201)],
    allocation:order_students(Students, Ordered),
    Ordered = [s(s0003, cs101), s(s0001, cs101), s(s0005, cs101),
               s(s0002, ma201)].

test(cohort_uses_tightest_room_that_fits) :-
    Slots0 = [slot(r101, 10, 2, 10, [], []),
              slot(r102, 3, 1, 10, [], [])],
    allocation:deal([s(s0001, cs101), s(s0005, cs101)],
                    Slots0, Slots, []),
    memberchk(slot(r101, 10, 2, 10, [], []), Slots),
    memberchk(slot(r102, 1, 1, 10, [cs101-2], _), Slots).

test(sample_session_uses_one_room_at_full_capacity) :-
    students_in_session(sess1, filters([], []), Students),
    allocation:open_rooms(Students, [spec(r101, 20, 2, 12)]).

test(uses_one_room_when_capacity_and_exam_limits_allow) :-
    Rooms = [spec(r12, 144, 12, 72), spec(r13, 144, 12, 72)],
    allocation:grow_prefix(Rooms, 135, 0,
                           [cs302-68, ma201-67], [], Chosen),
    Chosen = [spec(r12, 144, 12, 72)].

test(uses_two_rooms_when_one_exam_exceeds_room_limit) :-
    Rooms = [spec(r12, 144, 12, 72), spec(r13, 144, 12, 72)],
    allocation:grow_prefix(Rooms, 135, 0, [cs302-135], [], Chosen),
    Chosen = Rooms.

:- end_tests(cohort_allocation).

:- begin_tests(cohort_room_preference, [setup(use_full_data)]).

% A room holds at most max_same_exam_per_room/2 students of one exam
% (45 in a 9x9 room), so a 50-student cohort is best split 45 + 5.
test(cs303_year_three_cohort_is_kept_together_as_much_as_capacity_allows) :-
    user:exam(cs303, Session),
    students_in_session(Session, filters([], []), Students),
    allocate_rooms(Session, Students, Allocation),
    aggregate_all(count, member(s(_, cs303), Students), Size),
    findall(Count,
            ( member(room_group(_, Group), Allocation),
              aggregate_all(count, member(s(_, cs303), Group), Count) ),
            Counts),
    max_list(Counts, MaxInOneRoom),
    aggregate_all(max(M), rules:max_same_exam_per_room(_, M), RoomLimit),
    MaxInOneRoom >= min(Size, RoomLimit).

:- end_tests(cohort_room_preference).


% ===========================================================================
% B: solve_room/4
% ===========================================================================

:- begin_tests(solver, [setup(use_sample_data)]).

test(solves_the_sample_room) :-
    students_in_session(sess1, filters([], []), Students),
    length(Short, 10), append(Short, _, Students),
    solve_room(sess1, r101, Short, Result),
    Result = ok(Assignments),
    length(Assignments, 10).

test(every_student_gets_exactly_one_seat) :-
    students_in_session(sess1, filters([], []), Students),
    length(Short, 8), append(Short, _, Students),
    solve_room(sess1, r101, Short, ok(As)),
    forall(member(s(Id, Code), Short),
           aggregate_all(count, member(assign(Id, Code, _, _, _), As), 1)).

test(no_seat_is_used_twice) :-
    students_in_session(sess1, filters([], []), Students),
    solve_room(sess1, r101, Students, Result),
    ( Result = ok(As)
    -> findall(R-C, member(assign(_, _, _, R, C), As), Seats),
       sort(Seats, Unique), length(Seats, N), length(Unique, N)
    ; true ).

test(accessible_students_get_accessible_seats) :-
    students_in_session(sess1, filters([], []), Students),
    include([s(Id,_)]>>needs_accessible(Id), Students, Access),
    Access \== [],
    append(Access, [], Group),
    solve_room(sess1, r101, Group, ok(As)),
    forall(member(assign(Id, _, Room, R, C), As),
           ( needs_accessible(Id) -> user:seat(Room, R, C, accessible) ; true )).

test(normal_students_use_earliest_column_major_seats) :-
    solve_room(sess1, r101,
               [s(s0001, cs101), s(s0005, cs101)], ok(As)),
    memberchk(assign(s0001, cs101, r101, 1, 1), As),
    memberchk(assign(s0005, cs101, r101, 2, 1), As).

test(separation_is_respected) :-
    students_in_session(sess1, filters([], []), Students),
    solve_room(sess1, r101, Students, Result),
    ( Result = ok(As)
    -> min_separation(S), Need is S + 1,
       \+ ( member(assign(A, E, Rm, Row, C1), As),
            member(assign(B, E, Rm, Row, C2), As),
            A @< B, abs(C1 - C2) < Need )
    ; true ).

test(reports_not_enough_seats) :-
    % r102 has 15 seats; ask it to hold 20 students
    students_in_session(sess1, filters([], []), Students),
    length(Students, 20),
    solve_room(sess1, r102, Students, failed(Reason)),
    Reason = not_enough_seats(r102, 20, 15).

test(reports_not_enough_accessible) :-
    % three accessible students but r102 only has two accessible seats
    Students = [s(s0003, cs101), s(s0014, ma201), s(s0003b, cs101)],
    assertz(user:student(s0003b, se, 1, wheelchair)),
    solve_room(sess1, r102, Students, failed(Reason)),
    retract(user:student(s0003b, se, 1, wheelchair)),
    Reason = not_enough_accessible(r102, 3, 2).

test(reports_no_solution_when_separation_cannot_hold) :-
    % 12 students of ONE exam in a 3x5 room: each row holds at most 3 of them,
    % so 9 is the ceiling and the solver must give up.
    numlist(1, 12, Ns),
    findall(s(Id, cs101), ( member(N, Ns), fake_id(N, Id) ), Students),
    forall(member(s(Id, _), Students),
           assertz(user:student(Id, se, 1, none))),
    solve_room(sess1, r102, Students, Result),
    forall(member(s(Id, _), Students),
           retractall(user:student(Id, _, _, _))),
    Result = failed(no_solution(r102)).

test(reports_search_limit_separately) :-
    solve_room(sess1, r101, [s(s0001, cs101)], Result, [budget(1)]),
    Result = failed(search_limit(r101)).

fake_id(N, Id) :- format(atom(Id), 'f~w', [N]).

test(empty_room_is_trivially_ok) :-
    solve_room(sess1, r101, [], ok([])).

test(unavailable_room_is_refused) :-
    assertz(user:room(rzzz, 2, 2, no)),
    assertz(user:seat(rzzz, 1, 1, normal)),
    solve_room(sess1, rzzz, [s(s0001, cs101)], failed(no_solution(rzzz))),
    retract(user:room(rzzz, 2, 2, no)),
    retract(user:seat(rzzz, 1, 1, normal)).

:- end_tests(solver).


% ===========================================================================
% A: validate_seating/4  -  injected violations must be caught
% ===========================================================================

:- begin_tests(validator, [setup(use_sample_data)]).

good_plan(Assignments) :-
    generate_seating(sess1, filters([], []), ok(Assignments)).

has_rule(Report, Rule) :-
    Report = invalid(Violations),
    memberchk(violation(Rule, _), Violations).

test(accepts_a_good_plan) :-
    good_plan(As),
    validate_seating(sess1, filters([], []), As, valid).

test(catches_a_duplicated_seat) :-
    good_plan([assign(S1, E1, R, Row, Col) | Rest]),
    Rest = [assign(S2, E2, _, _, _) | Tail],
    Broken = [assign(S1, E1, R, Row, Col),
              assign(S2, E2, R, Row, Col) | Tail],
    validate_seating(sess1, filters([], []), Broken, Report),
    has_rule(Report, seat_unique).

test(catches_a_student_with_two_seats) :-
    good_plan([assign(S, E, R, Row, Col) | Rest]),
    Broken = [assign(S, E, R, Row, Col), assign(S, E, R, 99, 99) | Rest],
    validate_seating(sess1, filters([], []), Broken, Report),
    has_rule(Report, one_seat_per_student).

test(catches_a_missing_student) :-
    good_plan([_ | Rest]),
    validate_seating(sess1, filters([], []), Rest, Report),
    has_rule(Report, missing_student).

test(catches_an_accessibility_violation) :-
    good_plan(As),
    % s0003 needs a wheelchair seat; move them to a normal one
    selectchk(assign(s0003, E, _, _, _), As, Others),
    user:seat(r101, 4, 5, normal),
    Broken = [assign(s0003, E, r101, 4, 5) | Others],
    validate_seating(sess1, filters([], []), Broken, Report),
    has_rule(Report, accessibility).

test(catches_a_separation_violation) :-
    % two cs101 students side by side in the same row
    Broken = [assign(s0001, cs101, r101, 2, 1),
              assign(s0005, cs101, r101, 2, 2)],
    validate_seating(sess1, filters([], []), Broken, Report),
    has_rule(Report, separation).

test(catches_an_unavailable_room) :-
    assertz(user:room(rno, 2, 2, no)),
    assertz(user:seat(rno, 1, 1, normal)),
    validate_seating(sess1, filters([], []),
                     [assign(s0001, cs101, rno, 1, 1)], Report),
    retract(user:room(rno, 2, 2, no)),
    retract(user:seat(rno, 1, 1, normal)),
    has_rule(Report, room_available).

test(catches_a_seat_that_does_not_exist) :-
    validate_seating(sess1, filters([], []),
                     [assign(s0001, cs101, r101, 99, 99)], Report),
    has_rule(Report, room_capacity).

test(catches_a_student_not_enrolled) :-
    good_plan(As),
    validate_seating(sess1, filters([], []),
                     [assign(s0001, ma201, r102, 3, 5) | As], Report),
    has_rule(Report, missing_student).

test(every_violation_has_a_message) :-
    validate_seating(sess1, filters([], []),
                     [assign(s0001, cs101, r101, 99, 99)], invalid(Vs)),
    forall(member(V, Vs),
           ( explain_violation(V, Text), atom_length(Text, L), L > 10 )).

:- end_tests(validator).


% ===========================================================================
% B: generate_seating/3 end to end
% ===========================================================================

:- begin_tests(pipeline_sample, [setup(use_sample_data)]).

test(sample_session_is_valid) :-
    generate_seating(sess1, filters([], []), Result),
    Result = ok(As),
    length(As, 20),
    validate_seating(sess1, filters([], []), As, valid).

test(filters_reduce_the_plan) :-
    generate_seating(sess1, filters([1], []), ok(As)),
    length(As, N), N =:= 10,
    validate_seating(sess1, filters([1], []), As, valid).

test(no_matching_students_gives_an_empty_plan) :-
    generate_seating(sess1, filters([4], []), ok([])).

:- end_tests(pipeline_sample).


:- begin_tests(pipeline_full, [setup(use_full_data)]).

test(every_session_solves_and_validates) :-
    list_sessions(Sessions),
    forall(member(S, Sessions),
           ( generate_seating(S, filters([], []), Result),
             ( Result = ok(As)
             -> validate_seating(S, filters([], []), As, Report),
                ( Report == valid
                -> true
                ; format(user_error, '~w invalid: ~q~n', [S, Report]), fail )
             ; format(user_error, '~w failed: ~q~n', [S, Result]), fail ) )).

test(sess1_seats_everyone_within_the_open_rooms) :-
    students_in_session(sess1, filters([], []), Students),
    length(Students, N),
    generate_seating(sess1, filters([], []), ok(As),
                     stats(N, Rooms, _Retries, _)),
    length(As, N),
    aggregate_all(count, rules:available_room(_, _, _), Open),
    Rooms =< Open,
    validate_seating(sess1, filters([], []), As, valid).

test(a_filtered_run_validates) :-
    generate_seating(sess2, filters([1, 2], [se, cs]), ok(As)),
    validate_seating(sess2, filters([1, 2], [se, cs]), As, valid).

test(result_rows_have_the_contract_shape) :-
    generate_seating(sess13, filters([], []), ok(As)),
    forall(member(A, As),
           ( A = assign(S, E, R, Row, Col),
             atom(S), atom(E), atom(R), integer(Row), integer(Col) )).

test(stats_are_reported) :-
    generate_seating(sess13, filters([], []), ok(_), stats(N, Rooms, Retries, Ms)),
    N > 0, Rooms > 0, Retries >= 0, Ms >= 0.

:- end_tests(pipeline_full).


% ===========================================================================
% Scenario datasets (tests/scenarios/*.pl): end-to-end edge cases
% ===========================================================================
% Each file is a tiny hand-checkable world. When the students cannot fit,
% generate_seating/3 must return failed(Reason) - never an ok plan with
% students silently left out.

use_scenario(Name) :-
    format(atom(File), 'tests/scenarios/~w.pl', [Name]),
    load_data_file(File).

scenario_ok(Name, Session, N) :-
    use_scenario(Name),
    generate_seating(Session, filters([], []), ok(As)),
    length(As, N),
    validate_seating(Session, filters([], []), As, valid).

scenario_fails(Name, Reason) :-
    use_scenario(Name),
    generate_seating(sess1, filters([], []), failed(Reason)).

:- begin_tests(scenarios, [cleanup(use_full_data)]).

test(two_exams_share_a_room) :-
    scenario_ok(ok_two_exams, sess1, 12).

test(only_the_requested_session_is_seated) :-
    scenario_ok(two_sessions, sess1, 6),
    scenario_ok(two_sessions, sess2, 4).

test(too_many_students_fails) :-
    scenario_fails(not_enough_seats, not_enough_seats(r101, 10, 8)).

test(too_few_accessible_seats_fails) :-
    scenario_fails(not_enough_accessible, not_enough_accessible(r101, 3, 2)).

test(separation_that_cannot_hold_fails) :-
    scenario_fails(separation_impossible, no_solution(r101)).

test(closed_room_is_never_used) :-
    scenario_fails(closed_room, not_enough_seats(r101, 8, 6)).

:- end_tests(scenarios).


% ===========================================================================
% Timetabling CSP (timetable.pl)
% ===========================================================================

conflicting(A, B) :-
    user:enrolled(St, A), user:enrolled(St, B), A \== B.

:- begin_tests(timetable, [cleanup(use_full_data)]).

test(full_data_timetable_is_clash_free_and_fits, [setup(use_full_data)]) :-
    build_timetable([fill(80)], ok(TT, stats(_, Peak, Limit, _))),
    forall(user:subject(C), memberchk(C-_, TT)),
    forall(( member(A-S, TT), member(B-S, TT), A @< B ),
           \+ conflicting(A, B)),
    Peak =< Limit.

test(generated_data_respects_the_fill_limit, [setup(use_full_data)]) :-
    total_capacity(Seats, ASeats),
    Limit is Seats * 80 // 100,
    list_sessions(Sessions),
    forall(member(S, Sessions),
           ( selection_size(S, filters([], []), N, NA),
             N =< Limit, NA =< ASeats )).

test(too_few_sessions_is_reported) :-
    use_scenario(tt_too_few_sessions),
    build_timetable([], failed(too_few_sessions(3, 2))).

test(capacity_splits_unrelated_subjects) :-
    use_scenario(tt_capacity),
    build_timetable([fill(60)], ok(TT, _)),
    memberchk(se101-S1, TT), memberchk(ce101-S2, TT),
    S1 \== S2.

test(unrelated_subjects_may_share_when_they_fit) :-
    use_scenario(tt_capacity),
    build_timetable([fill(100)], ok(TT, _)),
    length(TT, 2).

test(subject_bigger_than_any_session_is_reported) :-
    use_scenario(tt_subject_too_large),
    build_timetable([fill(100)], failed(subject_too_large(se101, 7, 6))).

test(every_failure_has_a_message) :-
    forall(member(R, [no_sessions, too_few_sessions(9, 4),
                      subject_too_large(x, 1, 0), no_timetable(3)]),
           ( explain_timetable_failure(R, T), atom(T) )).

:- end_tests(timetable).


% ===========================================================================
% Capacity counter and whole-term run (main.pl)
% ===========================================================================

:- begin_tests(term, [setup(use_full_data)]).

test(cohorts_add_up_to_the_session) :-
    session_cohorts(sess1, Cohorts),
    aggregate_all(sum(N), member(cohort(_, _, N, _, _), Cohorts), Sum),
    selection_size(sess1, filters([], []), Sum, _).

test(selection_size_follows_filters) :-
    selection_size(sess1, filters([], []), All, _),
    selection_size(sess1, filters([1], []), Y1, _),
    Y1 > 0, Y1 < All.

test(capacity_counts_only_open_rooms) :-
    total_capacity(Seats, _),
    aggregate_all(count, ( user:room(R, _, _, yes), user:seat(R, _, _, _) ), Seats).

test(whole_term_finishes_every_cohort) :-
    seat_term(Reports, Coverage),
    forall(member(term_session(_, Status, _, _, _), Reports), Status == ok),
    forall(member(cohort(_, _, Done, Total), Coverage), Done == Total),
    aggregate_all(count, user:enrolled(_, _), AllExams),
    aggregate_all(sum(T), member(cohort(_, _, _, T), Coverage), AllExams).

:- end_tests(term).
