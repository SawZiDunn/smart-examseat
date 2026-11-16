% Timetabling scenario: one subject is bigger than any session
% 7 students sit se101 but a 2x5 room holds at most 6 of ONE exam (3 per
% row, because same-exam students must sit apart).
% Expected: build_timetable fails with subject_too_large(se101, 7, 6).

:- discontiguous student/4, student_name/2, subject/1, enrolled/2,
                 exam/2, session_time/4, room/4, seat/4.
:- dynamic exam/2.

session_time(sess1, '2026-12-01', '09:00', '12:00').

subject(se101).

room(r101, 2, 5, yes).
seat(r101,1,1,accessible). seat(r101,1,2,normal). seat(r101,1,3,normal). seat(r101,1,4,normal). seat(r101,1,5,normal).
seat(r101,2,1,normal). seat(r101,2,2,normal). seat(r101,2,3,normal). seat(r101,2,4,normal). seat(r101,2,5,normal).

student(s0001, se, 1, none).  student_name(s0001, 'Student 0001').  enrolled(s0001, se101).
student(s0002, se, 1, none).  student_name(s0002, 'Student 0002').  enrolled(s0002, se101).
student(s0003, se, 1, none).  student_name(s0003, 'Student 0003').  enrolled(s0003, se101).
student(s0004, se, 1, none).  student_name(s0004, 'Student 0004').  enrolled(s0004, se101).
student(s0005, se, 1, none).  student_name(s0005, 'Student 0005').  enrolled(s0005, se101).
student(s0006, se, 1, none).  student_name(s0006, 'Student 0006').  enrolled(s0006, se101).
student(s0007, se, 1, none).  student_name(s0007, 'Student 0007').  enrolled(s0007, se101).
