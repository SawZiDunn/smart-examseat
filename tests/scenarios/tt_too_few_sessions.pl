% Timetabling scenario: too_few_sessions
% One cohort sits 3 subjects, but the exam period only has 2 sessions.
% Expected: build_timetable fails with too_few_sessions(3, 2).

:- discontiguous student/4, student_name/2, subject/1, enrolled/2,
                 exam/2, session_time/4, room/4, seat/4.
:- dynamic exam/2.

session_time(sess1, '2026-12-01', '09:00', '12:00').
session_time(sess2, '2026-12-01', '13:00', '16:00').

subject(se101).  subject(se102).  subject(se103).

room(r101, 2, 5, yes).
seat(r101,1,1,accessible). seat(r101,1,2,normal). seat(r101,1,3,normal). seat(r101,1,4,normal). seat(r101,1,5,normal).
seat(r101,2,1,normal). seat(r101,2,2,normal). seat(r101,2,3,normal). seat(r101,2,4,normal). seat(r101,2,5,normal).

student(s0001, se, 1, none).  student_name(s0001, 'Student 0001').
student(s0002, se, 1, none).  student_name(s0002, 'Student 0002').
enrolled(s0001, se101). enrolled(s0001, se102). enrolled(s0001, se103).
enrolled(s0002, se101). enrolled(s0002, se102). enrolled(s0002, se103).
