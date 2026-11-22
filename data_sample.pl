% SmartExamSeat tiny sample dataset
% GENERATED FILE - produced by generate_data.py from config.toml,
% do not edit by hand. Schema: README.md section 8.2.

:- discontiguous student/4.
:- discontiguous student_name/2.
:- discontiguous subject/1.
:- discontiguous enrolled/2.
:- discontiguous exam/2.
:- discontiguous session_time/4.
:- discontiguous room/4.
:- discontiguous seat/4.
:- dynamic exam/2.

% ---- sessions (1) ----
session_time(sess1, '2026-12-01', '09:00', '12:00').

% ---- subjects (2) ----
subject(cs101).
subject(ma201).

% ---- exams (timetable from timetable.pl) (2) ----
exam(cs101, sess1).
exam(ma201, sess1).

% ---- rooms (2) ----
room(r101, 4, 5, yes).
room(r102, 3, 5, yes).

% ---- seats (35) ----
seat(r101, 1, 1, accessible).
seat(r101, 1, 2, normal).
seat(r101, 1, 3, accessible).
seat(r101, 1, 4, normal).
seat(r101, 1, 5, normal).
seat(r101, 2, 1, normal).
seat(r101, 2, 2, normal).
seat(r101, 2, 3, normal).
seat(r101, 2, 4, normal).
seat(r101, 2, 5, normal).
seat(r101, 3, 1, normal).
seat(r101, 3, 2, normal).
seat(r101, 3, 3, normal).
seat(r101, 3, 4, normal).
seat(r101, 3, 5, normal).
seat(r101, 4, 1, normal).
seat(r101, 4, 2, normal).
seat(r101, 4, 3, normal).
seat(r101, 4, 4, normal).
seat(r101, 4, 5, normal).
seat(r102, 1, 1, accessible).
seat(r102, 1, 2, normal).
seat(r102, 1, 3, accessible).
seat(r102, 1, 4, normal).
seat(r102, 1, 5, normal).
seat(r102, 2, 1, normal).
seat(r102, 2, 2, normal).
seat(r102, 2, 3, normal).
seat(r102, 2, 4, normal).
seat(r102, 2, 5, normal).
seat(r102, 3, 1, normal).
seat(r102, 3, 2, normal).
seat(r102, 3, 3, normal).
seat(r102, 3, 4, normal).
seat(r102, 3, 5, normal).

% ---- students (20) ----
student(s0001, se, 1, none).
student(s0002, cs, 1, none).
student(s0003, se, 1, wheelchair).
student(s0004, cs, 1, none).
student(s0005, se, 1, none).
student(s0006, cs, 1, none).
student(s0007, se, 1, none).
student(s0008, cs, 1, none).
student(s0009, se, 1, none).
student(s0010, cs, 1, none).
student(s0011, se, 2, none).
student(s0012, cs, 2, none).
student(s0013, se, 2, none).
student(s0014, cs, 2, wheelchair).
student(s0015, se, 2, none).
student(s0016, cs, 2, none).
student(s0017, se, 2, none).
student(s0018, cs, 2, none).
student(s0019, se, 2, none).
student(s0020, cs, 2, none).

% ---- student names (20) ----
student_name(s0001, 'Aung Hlaing').
student_name(s0002, 'Mya Oo').
student_name(s0003, 'Thandar Win').
student_name(s0004, 'Kyaw Htun').
student_name(s0005, 'Nilar Aye').
student_name(s0006, 'Zaw Naing').
student_name(s0007, 'Hnin Lin').
student_name(s0008, 'Soe Maung').
student_name(s0009, 'Ei Kyi').
student_name(s0010, 'Min Thu').
student_name(s0011, 'Thiri Swe').
student_name(s0012, 'Htet Mon').
student_name(s0013, 'Yadanar Nyein').
student_name(s0014, 'Phyo Sann').
student_name(s0015, 'Chan Htay').
student_name(s0016, 'Nay Phyu').
student_name(s0017, 'Su Zaw').
student_name(s0018, 'Wai Myint').
student_name(s0019, 'Kaung Tin').
student_name(s0020, 'May Latt').

% ---- enrolments (20) ----
enrolled(s0001, cs101).
enrolled(s0002, cs101).
enrolled(s0003, cs101).
enrolled(s0004, cs101).
enrolled(s0005, cs101).
enrolled(s0006, cs101).
enrolled(s0007, cs101).
enrolled(s0008, cs101).
enrolled(s0009, cs101).
enrolled(s0010, cs101).
enrolled(s0011, ma201).
enrolled(s0012, ma201).
enrolled(s0013, ma201).
enrolled(s0014, ma201).
enrolled(s0015, ma201).
enrolled(s0016, ma201).
enrolled(s0017, ma201).
enrolled(s0018, ma201).
enrolled(s0019, ma201).
enrolled(s0020, ma201).
