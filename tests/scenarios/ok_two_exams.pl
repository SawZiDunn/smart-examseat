% Scenario: ok_two_exams
% Baseline: two exams share one 3x4 room and can alternate columns.
% Expected: ok, 12 students in r101, validator valid
% Run: python3 bridge.py sess1 --dataset tests/scenarios/ok_two_exams.pl

:- discontiguous student/4, student_name/2, subject/1, enrolled/2,
                 exam/2, session_time/4, room/4, seat/4.

session_time(sess1, '2026-12-01', '09:00', '12:00').

subject(cs101).  exam(cs101, sess1).
subject(ma201).  exam(ma201, sess1).

room(r101, 3, 4, yes).
seat(r101,1,1,accessible). seat(r101,1,2,normal). seat(r101,1,3,accessible). seat(r101,1,4,normal).
seat(r101,2,1,normal). seat(r101,2,2,normal). seat(r101,2,3,normal). seat(r101,2,4,normal).
seat(r101,3,1,normal). seat(r101,3,2,normal). seat(r101,3,3,normal). seat(r101,3,4,normal).

student(s0001, cs, 1, none).  student_name(s0001, 'Student 0001').  enrolled(s0001, cs101).
student(s0002, cs, 1, none).  student_name(s0002, 'Student 0002').  enrolled(s0002, cs101).
student(s0003, cs, 1, none).  student_name(s0003, 'Student 0003').  enrolled(s0003, cs101).
student(s0004, cs, 1, none).  student_name(s0004, 'Student 0004').  enrolled(s0004, cs101).
student(s0005, cs, 1, none).  student_name(s0005, 'Student 0005').  enrolled(s0005, cs101).
student(s0006, cs, 1, none).  student_name(s0006, 'Student 0006').  enrolled(s0006, cs101).
student(s0007, se, 2, none).  student_name(s0007, 'Student 0007').  enrolled(s0007, ma201).
student(s0008, se, 2, none).  student_name(s0008, 'Student 0008').  enrolled(s0008, ma201).
student(s0009, se, 2, none).  student_name(s0009, 'Student 0009').  enrolled(s0009, ma201).
student(s0010, se, 2, none).  student_name(s0010, 'Student 0010').  enrolled(s0010, ma201).
student(s0011, se, 2, none).  student_name(s0011, 'Student 0011').  enrolled(s0011, ma201).
student(s0012, se, 2, none).  student_name(s0012, 'Student 0012').  enrolled(s0012, ma201).
