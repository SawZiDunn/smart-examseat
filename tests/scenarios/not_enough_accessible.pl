% Scenario: not_enough_accessible
% 3 wheelchair students but the only room has 2 accessible seats.
% Expected: failed: not enough accessible seats
% Run: python3 bridge.py sess1 --dataset tests/scenarios/not_enough_accessible.pl

:- discontiguous student/4, student_name/2, subject/1, enrolled/2,
                 exam/2, session_time/4, room/4, seat/4.

session_time(sess1, '2026-12-01', '09:00', '12:00').

subject(cs101).  exam(cs101, sess1).

room(r101, 3, 4, yes).
seat(r101,1,1,accessible). seat(r101,1,2,normal). seat(r101,1,3,accessible). seat(r101,1,4,normal).
seat(r101,2,1,normal). seat(r101,2,2,normal). seat(r101,2,3,normal). seat(r101,2,4,normal).
seat(r101,3,1,normal). seat(r101,3,2,normal). seat(r101,3,3,normal). seat(r101,3,4,normal).

student(s0001, cs, 1, wheelchair).  student_name(s0001, 'Student 0001').  enrolled(s0001, cs101).
student(s0002, cs, 1, wheelchair).  student_name(s0002, 'Student 0002').  enrolled(s0002, cs101).
student(s0003, cs, 1, other_accessible).  student_name(s0003, 'Student 0003').  enrolled(s0003, cs101).
student(s0004, cs, 1, none).  student_name(s0004, 'Student 0004').  enrolled(s0004, cs101).
