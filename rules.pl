% ===========================================================================
% rules.pl  -  shared constants and derived rules            (Member A)
% ===========================================================================
% Everything in here is read by allocation.pl, solver.pl and validator.pl.
% It contains no search: only the vocabulary the rest of the system speaks.
% ===========================================================================

:- module(rules, [
        min_separation/1,
        max_retries/1,
        available_room/3,
        room_capacity/2,
        room_accessible_capacity/2,
        max_same_exam_per_room/2,
        total_capacity/2,
        needs_accessible/1,
        seat_fits/2,
        separation_ok/3,
        room_seats/2,
        accessible_seats/2,
        matches_filters/2,
        exam_of/2,
        student_major/2,
        student_year/2
   ]).

:- use_module(library(lists)).

% The data facts live in the user module (data.pl is consulted by main.pl),
% so declare them here to keep the module system happy.
:- dynamic
        user:student/4,
        user:student_name/2,
        user:subject/1,
        user:enrolled/2,
        user:exam/2,
        user:session_time/4,
        user:room/4,
        user:seat/4.


% ---------------------------------------------------------------------------
% 1. Constants (CONTRACT.md section 6)
% ---------------------------------------------------------------------------

%! min_separation(-N) is det.
%  Two students sitting the SAME exam in the SAME row must be at least
%  N empty seats apart, i.e. their column distance must be >= N + 1.
min_separation(1).

%! max_retries(-N) is det.
%  How many times generate_seating/3 may ask the allocator to reshuffle a
%  room that the solver could not satisfy.
max_retries(3).


% ---------------------------------------------------------------------------
% 2. Rooms and seats
% ---------------------------------------------------------------------------

%! available_room(?RoomId, ?Rows, ?Cols) is nondet.
%  Only rooms flagged `yes` may ever be used (hard constraint room_available).
available_room(RoomId, Rows, Cols) :-
    user:room(RoomId, Rows, Cols, yes).

%! room_seats(+RoomId, -Seats) is det.
%  Seats = [seat(Row, Col, SeatType), ...] in row-major order.
room_seats(RoomId, Seats) :-
    findall(seat(Row, Col, Type),
            user:seat(RoomId, Row, Col, Type),
            Unsorted),
    sort(Unsorted, Seats).           % sort/2 on seat(Row,Col,_) == row-major

%! accessible_seats(+RoomId, -Seats) is det.
accessible_seats(RoomId, Seats) :-
    findall(seat(Row, Col, accessible),
            user:seat(RoomId, Row, Col, accessible),
            Unsorted),
    sort(Unsorted, Seats).

%! room_capacity(+RoomId, -N) is det.
%  Total number of physical seats in an available room.
room_capacity(RoomId, N) :-
    available_room(RoomId, _, _),
    aggregate_all(count, user:seat(RoomId, _, _, _), N).

%! room_accessible_capacity(+RoomId, -N) is det.
room_accessible_capacity(RoomId, N) :-
    available_room(RoomId, _, _),
    aggregate_all(count, user:seat(RoomId, _, _, accessible), N).

%! max_same_exam_per_room(+RoomId, -N) is det.
%  Upper bound on how many students of ONE exam a room can hold.
%
%  The separation rule only bites inside a row: with min_separation(S) a row
%  of C columns can hold at most ceil(C / (S+1)) students of the same exam.
%  The allocator uses this so it never hands the solver a room that is
%  provably unsolvable.
max_same_exam_per_room(RoomId, N) :-
    available_room(RoomId, Rows, Cols),
    min_separation(S),
    Step is S + 1,
    PerRow is (Cols + Step - 1) // Step,
    N is Rows * PerRow.

%! total_capacity(-Seats, -AccessibleSeats) is det.
%  Seats across every available room: the most students one session can
%  ever hold. The UI caps a year/major selection at this number and the
%  timetabler keeps each session under a share of it.
total_capacity(Seats, AccessibleSeats) :-
    aggregate_all(sum(N), room_capacity(_, N), Seats),
    aggregate_all(sum(N), room_accessible_capacity(_, N), AccessibleSeats).


% ---------------------------------------------------------------------------
% 3. Students
% ---------------------------------------------------------------------------

%! needs_accessible(+StudentId) is semidet.
needs_accessible(StudentId) :-
    user:student(StudentId, _, _, Access),
    Access \== none.

%! seat_fits(+StudentId, +SeatType) is semidet.
%  A student who needs accessibility may ONLY take an accessible seat.
%  A student who does not need it may take either kind (accessible seats are
%  not reserved, but the allocator keeps enough of them free in practice).
seat_fits(StudentId, accessible) :-
    !,
    user:student(StudentId, _, _, _).
seat_fits(StudentId, normal) :-
    \+ needs_accessible(StudentId).

student_major(StudentId, Major) :- user:student(StudentId, Major, _, _).
student_year(StudentId, Year)   :- user:student(StudentId, _, Year, _).


% ---------------------------------------------------------------------------
% 4. Separation
% ---------------------------------------------------------------------------

%! separation_ok(+Row, +Col, +OccupiedColsInThisRowForThisExam) is semidet.
%  True when placing a student of some exam at (Row, Col) keeps the required
%  distance from every student of the SAME exam already seated in that row.
separation_ok(_Row, Col, Cols) :-
    min_separation(S),
    Need is S + 1,
    forall(member(Other, Cols),
           ( D is abs(Col - Other), D >= Need )).


% ---------------------------------------------------------------------------
% 5. Filters (CONTRACT.md section 4)
% ---------------------------------------------------------------------------

%! matches_filters(+StudentId, +Filters) is semidet.
%  Filters = filters(Years, Majors); an empty list means "no restriction".
matches_filters(StudentId, filters(Years, Majors)) :-
    user:student(StudentId, Major, Year, _),
    ( Years  == [] -> true ; memberchk(Year, Years) ),
    ( Majors == [] -> true ; memberchk(Major, Majors) ).


% ---------------------------------------------------------------------------
% 6. Exams
% ---------------------------------------------------------------------------

%! exam_of(+Code, -Session) is semidet.
exam_of(Code, Session) :-
    user:exam(Code, Session).
