% SmartExamSeat full dataset
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

% ---- sessions (4) ----
session_time(sess1, '2026-12-01', '09:00', '12:00').
session_time(sess2, '2026-12-01', '13:00', '16:00').
session_time(sess3, '2026-12-02', '09:00', '12:00').
session_time(sess4, '2026-12-02', '13:00', '16:00').

% ---- subjects (12) ----
subject(se101).
subject(se102).
subject(se103).
subject(se201).
subject(se202).
subject(cs101).
subject(cs102).
subject(cs103).
subject(cs201).
subject(cs202).
subject(ee201).
subject(ee202).

% ---- exams (timetable from timetable.pl) (12) ----
exam(cs101, sess1).
exam(cs102, sess3).
exam(cs103, sess2).
exam(cs201, sess3).
exam(cs202, sess1).
exam(ee201, sess4).
exam(ee202, sess2).
exam(se101, sess4).
exam(se102, sess1).
exam(se103, sess2).
exam(se201, sess3).
exam(se202, sess1).

% ---- rooms (3) ----
room(r101, 8, 8, yes).
room(r102, 8, 8, yes).
room(r103, 8, 8, no).

% ---- seats (192) ----
seat(r101, 1, 1, accessible).
seat(r101, 1, 2, normal).
seat(r101, 1, 3, accessible).
seat(r101, 1, 4, normal).
seat(r101, 1, 5, accessible).
seat(r101, 1, 6, normal).
seat(r101, 1, 7, accessible).
seat(r101, 1, 8, normal).
seat(r101, 2, 1, normal).
seat(r101, 2, 2, normal).
seat(r101, 2, 3, normal).
seat(r101, 2, 4, normal).
seat(r101, 2, 5, normal).
seat(r101, 2, 6, normal).
seat(r101, 2, 7, normal).
seat(r101, 2, 8, normal).
seat(r101, 3, 1, normal).
seat(r101, 3, 2, normal).
seat(r101, 3, 3, normal).
seat(r101, 3, 4, normal).
seat(r101, 3, 5, normal).
seat(r101, 3, 6, normal).
seat(r101, 3, 7, normal).
seat(r101, 3, 8, normal).
seat(r101, 4, 1, normal).
seat(r101, 4, 2, normal).
seat(r101, 4, 3, normal).
seat(r101, 4, 4, normal).
seat(r101, 4, 5, normal).
seat(r101, 4, 6, normal).
seat(r101, 4, 7, normal).
seat(r101, 4, 8, normal).
seat(r101, 5, 1, normal).
seat(r101, 5, 2, normal).
seat(r101, 5, 3, normal).
seat(r101, 5, 4, normal).
seat(r101, 5, 5, normal).
seat(r101, 5, 6, normal).
seat(r101, 5, 7, normal).
seat(r101, 5, 8, normal).
seat(r101, 6, 1, normal).
seat(r101, 6, 2, normal).
seat(r101, 6, 3, normal).
seat(r101, 6, 4, normal).
seat(r101, 6, 5, normal).
seat(r101, 6, 6, normal).
seat(r101, 6, 7, normal).
seat(r101, 6, 8, normal).
seat(r101, 7, 1, normal).
seat(r101, 7, 2, normal).
seat(r101, 7, 3, normal).
seat(r101, 7, 4, normal).
seat(r101, 7, 5, normal).
seat(r101, 7, 6, normal).
seat(r101, 7, 7, normal).
seat(r101, 7, 8, normal).
seat(r101, 8, 1, normal).
seat(r101, 8, 2, normal).
seat(r101, 8, 3, normal).
seat(r101, 8, 4, normal).
seat(r101, 8, 5, normal).
seat(r101, 8, 6, normal).
seat(r101, 8, 7, normal).
seat(r101, 8, 8, normal).
seat(r102, 1, 1, accessible).
seat(r102, 1, 2, normal).
seat(r102, 1, 3, accessible).
seat(r102, 1, 4, normal).
seat(r102, 1, 5, accessible).
seat(r102, 1, 6, normal).
seat(r102, 1, 7, accessible).
seat(r102, 1, 8, normal).
seat(r102, 2, 1, normal).
seat(r102, 2, 2, normal).
seat(r102, 2, 3, normal).
seat(r102, 2, 4, normal).
seat(r102, 2, 5, normal).
seat(r102, 2, 6, normal).
seat(r102, 2, 7, normal).
seat(r102, 2, 8, normal).
seat(r102, 3, 1, normal).
seat(r102, 3, 2, normal).
seat(r102, 3, 3, normal).
seat(r102, 3, 4, normal).
seat(r102, 3, 5, normal).
seat(r102, 3, 6, normal).
seat(r102, 3, 7, normal).
seat(r102, 3, 8, normal).
seat(r102, 4, 1, normal).
seat(r102, 4, 2, normal).
seat(r102, 4, 3, normal).
seat(r102, 4, 4, normal).
seat(r102, 4, 5, normal).
seat(r102, 4, 6, normal).
seat(r102, 4, 7, normal).
seat(r102, 4, 8, normal).
seat(r102, 5, 1, normal).
seat(r102, 5, 2, normal).
seat(r102, 5, 3, normal).
seat(r102, 5, 4, normal).
seat(r102, 5, 5, normal).
seat(r102, 5, 6, normal).
seat(r102, 5, 7, normal).
seat(r102, 5, 8, normal).
seat(r102, 6, 1, normal).
seat(r102, 6, 2, normal).
seat(r102, 6, 3, normal).
seat(r102, 6, 4, normal).
seat(r102, 6, 5, normal).
seat(r102, 6, 6, normal).
seat(r102, 6, 7, normal).
seat(r102, 6, 8, normal).
seat(r102, 7, 1, normal).
seat(r102, 7, 2, normal).
seat(r102, 7, 3, normal).
seat(r102, 7, 4, normal).
seat(r102, 7, 5, normal).
seat(r102, 7, 6, normal).
seat(r102, 7, 7, normal).
seat(r102, 7, 8, normal).
seat(r102, 8, 1, normal).
seat(r102, 8, 2, normal).
seat(r102, 8, 3, normal).
seat(r102, 8, 4, normal).
seat(r102, 8, 5, normal).
seat(r102, 8, 6, normal).
seat(r102, 8, 7, normal).
seat(r102, 8, 8, normal).
seat(r103, 1, 1, accessible).
seat(r103, 1, 2, normal).
seat(r103, 1, 3, accessible).
seat(r103, 1, 4, normal).
seat(r103, 1, 5, accessible).
seat(r103, 1, 6, normal).
seat(r103, 1, 7, accessible).
seat(r103, 1, 8, normal).
seat(r103, 2, 1, normal).
seat(r103, 2, 2, normal).
seat(r103, 2, 3, normal).
seat(r103, 2, 4, normal).
seat(r103, 2, 5, normal).
seat(r103, 2, 6, normal).
seat(r103, 2, 7, normal).
seat(r103, 2, 8, normal).
seat(r103, 3, 1, normal).
seat(r103, 3, 2, normal).
seat(r103, 3, 3, normal).
seat(r103, 3, 4, normal).
seat(r103, 3, 5, normal).
seat(r103, 3, 6, normal).
seat(r103, 3, 7, normal).
seat(r103, 3, 8, normal).
seat(r103, 4, 1, normal).
seat(r103, 4, 2, normal).
seat(r103, 4, 3, normal).
seat(r103, 4, 4, normal).
seat(r103, 4, 5, normal).
seat(r103, 4, 6, normal).
seat(r103, 4, 7, normal).
seat(r103, 4, 8, normal).
seat(r103, 5, 1, normal).
seat(r103, 5, 2, normal).
seat(r103, 5, 3, normal).
seat(r103, 5, 4, normal).
seat(r103, 5, 5, normal).
seat(r103, 5, 6, normal).
seat(r103, 5, 7, normal).
seat(r103, 5, 8, normal).
seat(r103, 6, 1, normal).
seat(r103, 6, 2, normal).
seat(r103, 6, 3, normal).
seat(r103, 6, 4, normal).
seat(r103, 6, 5, normal).
seat(r103, 6, 6, normal).
seat(r103, 6, 7, normal).
seat(r103, 6, 8, normal).
seat(r103, 7, 1, normal).
seat(r103, 7, 2, normal).
seat(r103, 7, 3, normal).
seat(r103, 7, 4, normal).
seat(r103, 7, 5, normal).
seat(r103, 7, 6, normal).
seat(r103, 7, 7, normal).
seat(r103, 7, 8, normal).
seat(r103, 8, 1, normal).
seat(r103, 8, 2, normal).
seat(r103, 8, 3, normal).
seat(r103, 8, 4, normal).
seat(r103, 8, 5, normal).
seat(r103, 8, 6, normal).
seat(r103, 8, 7, normal).
seat(r103, 8, 8, normal).

% ---- students (120) ----
student(s0001, se, 1, none).
student(s0002, se, 1, none).
student(s0003, se, 1, none).
student(s0004, se, 1, none).
student(s0005, se, 1, none).
student(s0006, se, 1, none).
student(s0007, se, 1, none).
student(s0008, se, 1, none).
student(s0009, se, 1, none).
student(s0010, se, 1, none).
student(s0011, se, 1, other_accessible).
student(s0012, se, 1, none).
student(s0013, se, 1, none).
student(s0014, se, 1, none).
student(s0015, se, 1, none).
student(s0016, se, 1, none).
student(s0017, se, 1, none).
student(s0018, se, 1, none).
student(s0019, se, 1, none).
student(s0020, se, 1, none).
student(s0021, se, 1, wheelchair).
student(s0022, se, 1, none).
student(s0023, se, 1, none).
student(s0024, se, 1, none).
student(s0025, se, 1, none).
student(s0026, se, 1, none).
student(s0027, se, 1, none).
student(s0028, se, 1, none).
student(s0029, se, 1, none).
student(s0030, se, 1, none).
student(s0031, se, 2, none).
student(s0032, se, 2, none).
student(s0033, se, 2, none).
student(s0034, se, 2, none).
student(s0035, se, 2, wheelchair).
student(s0036, se, 2, none).
student(s0037, se, 2, none).
student(s0038, se, 2, none).
student(s0039, se, 2, none).
student(s0040, se, 2, none).
student(s0041, se, 2, wheelchair).
student(s0042, se, 2, none).
student(s0043, se, 2, none).
student(s0044, se, 2, none).
student(s0045, se, 2, wheelchair).
student(s0046, se, 2, none).
student(s0047, se, 2, none).
student(s0048, se, 2, none).
student(s0049, se, 2, none).
student(s0050, se, 2, none).
student(s0051, cs, 1, none).
student(s0052, cs, 1, none).
student(s0053, cs, 1, none).
student(s0054, cs, 1, none).
student(s0055, cs, 1, none).
student(s0056, cs, 1, none).
student(s0057, cs, 1, none).
student(s0058, cs, 1, none).
student(s0059, cs, 1, none).
student(s0060, cs, 1, none).
student(s0061, cs, 1, none).
student(s0062, cs, 1, none).
student(s0063, cs, 1, none).
student(s0064, cs, 1, none).
student(s0065, cs, 1, none).
student(s0066, cs, 1, none).
student(s0067, cs, 1, none).
student(s0068, cs, 1, none).
student(s0069, cs, 1, none).
student(s0070, cs, 1, none).
student(s0071, cs, 1, none).
student(s0072, cs, 1, none).
student(s0073, cs, 1, none).
student(s0074, cs, 1, none).
student(s0075, cs, 1, none).
student(s0076, cs, 1, none).
student(s0077, cs, 1, none).
student(s0078, cs, 1, none).
student(s0079, cs, 1, none).
student(s0080, cs, 1, none).
student(s0081, cs, 2, none).
student(s0082, cs, 2, none).
student(s0083, cs, 2, none).
student(s0084, cs, 2, none).
student(s0085, cs, 2, none).
student(s0086, cs, 2, none).
student(s0087, cs, 2, none).
student(s0088, cs, 2, none).
student(s0089, cs, 2, none).
student(s0090, cs, 2, none).
student(s0091, cs, 2, none).
student(s0092, cs, 2, none).
student(s0093, cs, 2, none).
student(s0094, cs, 2, none).
student(s0095, cs, 2, none).
student(s0096, cs, 2, none).
student(s0097, cs, 2, none).
student(s0098, cs, 2, none).
student(s0099, cs, 2, none).
student(s0100, cs, 2, none).
student(s0101, ee, 2, none).
student(s0102, ee, 2, none).
student(s0103, ee, 2, none).
student(s0104, ee, 2, none).
student(s0105, ee, 2, none).
student(s0106, ee, 2, none).
student(s0107, ee, 2, none).
student(s0108, ee, 2, none).
student(s0109, ee, 2, none).
student(s0110, ee, 2, none).
student(s0111, ee, 2, none).
student(s0112, ee, 2, none).
student(s0113, ee, 2, none).
student(s0114, ee, 2, none).
student(s0115, ee, 2, none).
student(s0116, ee, 2, none).
student(s0117, ee, 2, none).
student(s0118, ee, 2, none).
student(s0119, ee, 2, none).
student(s0120, ee, 2, none).

% ---- student names (120) ----
student_name(s0001, 'Nay Latt').
student_name(s0002, 'Zaw Htay').
student_name(s0003, 'Yee Htun').
student_name(s0004, 'Soe Zaw').
student_name(s0005, 'Nilar Win').
student_name(s0006, 'Nay Naing').
student_name(s0007, 'Nanda Swe').
student_name(s0008, 'Yee Aye').
student_name(s0009, 'Htet Naing').
student_name(s0010, 'May Sann').
student_name(s0011, 'Pyae Swe').
student_name(s0012, 'Htet Nyein').
student_name(s0013, 'Shwe Swe').
student_name(s0014, 'Hnin Htun').
student_name(s0015, 'Zin Htun').
student_name(s0016, 'Chan Mon').
student_name(s0017, 'Lwin Htun').
student_name(s0018, 'Kyaw Htun').
student_name(s0019, 'May Kyi').
student_name(s0020, 'Htet Hlaing').
student_name(s0021, 'Min Thu').
student_name(s0022, 'Yee Aye').
student_name(s0023, 'Khin Aye').
student_name(s0024, 'Zin Myint').
student_name(s0025, 'Thiri Zaw').
student_name(s0026, 'Su Htay').
student_name(s0027, 'Lwin Thu').
student_name(s0028, 'Kyaw Tin').
student_name(s0029, 'Kyaw Oo').
student_name(s0030, 'Zaw Aye').
student_name(s0031, 'Wai Kyi').
student_name(s0032, 'Moe Hlaing').
student_name(s0033, 'Kyaw Kyi').
student_name(s0034, 'Pyae Nyein').
student_name(s0035, 'Wai Win').
student_name(s0036, 'Yee Latt').
student_name(s0037, 'Aung Kyi').
student_name(s0038, 'Chan Mon').
student_name(s0039, 'Kyaw Naing').
student_name(s0040, 'May Phyu').
student_name(s0041, 'Kyaw Hlaing').
student_name(s0042, 'Kyaw Phyu').
student_name(s0043, 'Soe Myint').
student_name(s0044, 'Htet Phyu').
student_name(s0045, 'Phyo Kyi').
student_name(s0046, 'Nay Swe').
student_name(s0047, 'Chan Kyi').
student_name(s0048, 'Mya Maung').
student_name(s0049, 'Tun Win').
student_name(s0050, 'Htet Thu').
student_name(s0051, 'Zaw Win').
student_name(s0052, 'Zaw Thu').
student_name(s0053, 'Hnin Phyu').
student_name(s0054, 'Mya Myint').
student_name(s0055, 'Yee Phyu').
student_name(s0056, 'Nilar Myint').
student_name(s0057, 'May Swe').
student_name(s0058, 'Thiri Oo').
student_name(s0059, 'Pyae Oo').
student_name(s0060, 'Khin Swe').
student_name(s0061, 'Nilar Mon').
student_name(s0062, 'Min Thu').
student_name(s0063, 'Mya Maung').
student_name(s0064, 'Myat Myint').
student_name(s0065, 'Zin Htay').
student_name(s0066, 'Chan Swe').
student_name(s0067, 'Shwe Zaw').
student_name(s0068, 'Su Naing').
student_name(s0069, 'Yadanar Mon').
student_name(s0070, 'Soe Naing').
student_name(s0071, 'Soe Lin').
student_name(s0072, 'Thiri Oo').
student_name(s0073, 'Shwe Lin').
student_name(s0074, 'Chan Htay').
student_name(s0075, 'Hnin Latt').
student_name(s0076, 'Kyaw Htun').
student_name(s0077, 'Pyae Nyein').
student_name(s0078, 'Htet Mon').
student_name(s0079, 'Wai Swe').
student_name(s0080, 'Shwe Maung').
student_name(s0081, 'Kaung Tin').
student_name(s0082, 'Phyo Htun').
student_name(s0083, 'Moe Thu').
student_name(s0084, 'Nay Phyu').
student_name(s0085, 'Hnin Mon').
student_name(s0086, 'Zaw Hlaing').
student_name(s0087, 'Yee Sann').
student_name(s0088, 'Lwin Oo').
student_name(s0089, 'Lwin Mon').
student_name(s0090, 'Su Naing').
student_name(s0091, 'Myat Mon').
student_name(s0092, 'Htet Myint').
student_name(s0093, 'Yee Phyu').
student_name(s0094, 'Shwe Kyi').
student_name(s0095, 'Yee Win').
student_name(s0096, 'Mya Zaw').
student_name(s0097, 'Lwin Win').
student_name(s0098, 'Su Oo').
student_name(s0099, 'Phyo Naing').
student_name(s0100, 'Nilar Thu').
student_name(s0101, 'Moe Htay').
student_name(s0102, 'Nanda Thu').
student_name(s0103, 'Thandar Naing').
student_name(s0104, 'Ei Myint').
student_name(s0105, 'Kaung Mon').
student_name(s0106, 'Phyo Phyu').
student_name(s0107, 'Yee Lin').
student_name(s0108, 'Su Hlaing').
student_name(s0109, 'Myat Tin').
student_name(s0110, 'Kyaw Maung').
student_name(s0111, 'Yadanar Maung').
student_name(s0112, 'Nilar Lin').
student_name(s0113, 'Pyae Htay').
student_name(s0114, 'Chan Mon').
student_name(s0115, 'Min Hlaing').
student_name(s0116, 'Shwe Myint').
student_name(s0117, 'Myat Maung').
student_name(s0118, 'Kyaw Phyu').
student_name(s0119, 'Mya Myint').
student_name(s0120, 'Kaung Zaw').

% ---- enrolments (300) ----
enrolled(s0001, se101).
enrolled(s0001, se102).
enrolled(s0001, se103).
enrolled(s0002, se101).
enrolled(s0002, se102).
enrolled(s0002, se103).
enrolled(s0003, se101).
enrolled(s0003, se102).
enrolled(s0003, se103).
enrolled(s0004, se101).
enrolled(s0004, se102).
enrolled(s0004, se103).
enrolled(s0005, se101).
enrolled(s0005, se102).
enrolled(s0005, se103).
enrolled(s0006, se101).
enrolled(s0006, se102).
enrolled(s0006, se103).
enrolled(s0007, se101).
enrolled(s0007, se102).
enrolled(s0007, se103).
enrolled(s0008, se101).
enrolled(s0008, se102).
enrolled(s0008, se103).
enrolled(s0009, se101).
enrolled(s0009, se102).
enrolled(s0009, se103).
enrolled(s0010, se101).
enrolled(s0010, se102).
enrolled(s0010, se103).
enrolled(s0011, se101).
enrolled(s0011, se102).
enrolled(s0011, se103).
enrolled(s0012, se101).
enrolled(s0012, se102).
enrolled(s0012, se103).
enrolled(s0013, se101).
enrolled(s0013, se102).
enrolled(s0013, se103).
enrolled(s0014, se101).
enrolled(s0014, se102).
enrolled(s0014, se103).
enrolled(s0015, se101).
enrolled(s0015, se102).
enrolled(s0015, se103).
enrolled(s0016, se101).
enrolled(s0016, se102).
enrolled(s0016, se103).
enrolled(s0017, se101).
enrolled(s0017, se102).
enrolled(s0017, se103).
enrolled(s0018, se101).
enrolled(s0018, se102).
enrolled(s0018, se103).
enrolled(s0019, se101).
enrolled(s0019, se102).
enrolled(s0019, se103).
enrolled(s0020, se101).
enrolled(s0020, se102).
enrolled(s0020, se103).
enrolled(s0021, se101).
enrolled(s0021, se102).
enrolled(s0021, se103).
enrolled(s0022, se101).
enrolled(s0022, se102).
enrolled(s0022, se103).
enrolled(s0023, se101).
enrolled(s0023, se102).
enrolled(s0023, se103).
enrolled(s0024, se101).
enrolled(s0024, se102).
enrolled(s0024, se103).
enrolled(s0025, se101).
enrolled(s0025, se102).
enrolled(s0025, se103).
enrolled(s0026, se101).
enrolled(s0026, se102).
enrolled(s0026, se103).
enrolled(s0027, se101).
enrolled(s0027, se102).
enrolled(s0027, se103).
enrolled(s0028, se101).
enrolled(s0028, se102).
enrolled(s0028, se103).
enrolled(s0029, se101).
enrolled(s0029, se102).
enrolled(s0029, se103).
enrolled(s0030, se101).
enrolled(s0030, se102).
enrolled(s0030, se103).
enrolled(s0031, se201).
enrolled(s0031, se202).
enrolled(s0032, se201).
enrolled(s0032, se202).
enrolled(s0033, se201).
enrolled(s0033, se202).
enrolled(s0034, se201).
enrolled(s0034, se202).
enrolled(s0035, se201).
enrolled(s0035, se202).
enrolled(s0036, se201).
enrolled(s0036, se202).
enrolled(s0037, se201).
enrolled(s0037, se202).
enrolled(s0038, se201).
enrolled(s0038, se202).
enrolled(s0039, se201).
enrolled(s0039, se202).
enrolled(s0040, se201).
enrolled(s0040, se202).
enrolled(s0041, se201).
enrolled(s0041, se202).
enrolled(s0042, se201).
enrolled(s0042, se202).
enrolled(s0043, se201).
enrolled(s0043, se202).
enrolled(s0044, se201).
enrolled(s0044, se202).
enrolled(s0045, se201).
enrolled(s0045, se202).
enrolled(s0046, se201).
enrolled(s0046, se202).
enrolled(s0047, se201).
enrolled(s0047, se202).
enrolled(s0048, se201).
enrolled(s0048, se202).
enrolled(s0049, se201).
enrolled(s0049, se202).
enrolled(s0050, se201).
enrolled(s0050, se202).
enrolled(s0051, cs101).
enrolled(s0051, cs102).
enrolled(s0051, cs103).
enrolled(s0052, cs101).
enrolled(s0052, cs102).
enrolled(s0052, cs103).
enrolled(s0053, cs101).
enrolled(s0053, cs102).
enrolled(s0053, cs103).
enrolled(s0054, cs101).
enrolled(s0054, cs102).
enrolled(s0054, cs103).
enrolled(s0055, cs101).
enrolled(s0055, cs102).
enrolled(s0055, cs103).
enrolled(s0056, cs101).
enrolled(s0056, cs102).
enrolled(s0056, cs103).
enrolled(s0057, cs101).
enrolled(s0057, cs102).
enrolled(s0057, cs103).
enrolled(s0058, cs101).
enrolled(s0058, cs102).
enrolled(s0058, cs103).
enrolled(s0059, cs101).
enrolled(s0059, cs102).
enrolled(s0059, cs103).
enrolled(s0060, cs101).
enrolled(s0060, cs102).
enrolled(s0060, cs103).
enrolled(s0061, cs101).
enrolled(s0061, cs102).
enrolled(s0061, cs103).
enrolled(s0062, cs101).
enrolled(s0062, cs102).
enrolled(s0062, cs103).
enrolled(s0063, cs101).
enrolled(s0063, cs102).
enrolled(s0063, cs103).
enrolled(s0064, cs101).
enrolled(s0064, cs102).
enrolled(s0064, cs103).
enrolled(s0065, cs101).
enrolled(s0065, cs102).
enrolled(s0065, cs103).
enrolled(s0066, cs101).
enrolled(s0066, cs102).
enrolled(s0066, cs103).
enrolled(s0067, cs101).
enrolled(s0067, cs102).
enrolled(s0067, cs103).
enrolled(s0068, cs101).
enrolled(s0068, cs102).
enrolled(s0068, cs103).
enrolled(s0069, cs101).
enrolled(s0069, cs102).
enrolled(s0069, cs103).
enrolled(s0070, cs101).
enrolled(s0070, cs102).
enrolled(s0070, cs103).
enrolled(s0071, cs101).
enrolled(s0071, cs102).
enrolled(s0071, cs103).
enrolled(s0072, cs101).
enrolled(s0072, cs102).
enrolled(s0072, cs103).
enrolled(s0073, cs101).
enrolled(s0073, cs102).
enrolled(s0073, cs103).
enrolled(s0074, cs101).
enrolled(s0074, cs102).
enrolled(s0074, cs103).
enrolled(s0075, cs101).
enrolled(s0075, cs102).
enrolled(s0075, cs103).
enrolled(s0076, cs101).
enrolled(s0076, cs102).
enrolled(s0076, cs103).
enrolled(s0077, cs101).
enrolled(s0077, cs102).
enrolled(s0077, cs103).
enrolled(s0078, cs101).
enrolled(s0078, cs102).
enrolled(s0078, cs103).
enrolled(s0079, cs101).
enrolled(s0079, cs102).
enrolled(s0079, cs103).
enrolled(s0080, cs101).
enrolled(s0080, cs102).
enrolled(s0080, cs103).
enrolled(s0081, cs201).
enrolled(s0081, cs202).
enrolled(s0082, cs201).
enrolled(s0082, cs202).
enrolled(s0083, cs201).
enrolled(s0083, cs202).
enrolled(s0084, cs201).
enrolled(s0084, cs202).
enrolled(s0085, cs201).
enrolled(s0085, cs202).
enrolled(s0086, cs201).
enrolled(s0086, cs202).
enrolled(s0087, cs201).
enrolled(s0087, cs202).
enrolled(s0088, cs201).
enrolled(s0088, cs202).
enrolled(s0089, cs201).
enrolled(s0089, cs202).
enrolled(s0090, cs201).
enrolled(s0090, cs202).
enrolled(s0091, cs201).
enrolled(s0091, cs202).
enrolled(s0092, cs201).
enrolled(s0092, cs202).
enrolled(s0093, cs201).
enrolled(s0093, cs202).
enrolled(s0094, cs201).
enrolled(s0094, cs202).
enrolled(s0095, cs201).
enrolled(s0095, cs202).
enrolled(s0096, cs201).
enrolled(s0096, cs202).
enrolled(s0097, cs201).
enrolled(s0097, cs202).
enrolled(s0098, cs201).
enrolled(s0098, cs202).
enrolled(s0099, cs201).
enrolled(s0099, cs202).
enrolled(s0100, cs201).
enrolled(s0100, cs202).
enrolled(s0101, ee201).
enrolled(s0101, ee202).
enrolled(s0102, ee201).
enrolled(s0102, ee202).
enrolled(s0103, ee201).
enrolled(s0103, ee202).
enrolled(s0104, ee201).
enrolled(s0104, ee202).
enrolled(s0105, ee201).
enrolled(s0105, ee202).
enrolled(s0106, ee201).
enrolled(s0106, ee202).
enrolled(s0107, ee201).
enrolled(s0107, ee202).
enrolled(s0108, ee201).
enrolled(s0108, ee202).
enrolled(s0109, ee201).
enrolled(s0109, ee202).
enrolled(s0110, ee201).
enrolled(s0110, ee202).
enrolled(s0111, ee201).
enrolled(s0111, ee202).
enrolled(s0112, ee201).
enrolled(s0112, ee202).
enrolled(s0113, ee201).
enrolled(s0113, ee202).
enrolled(s0114, ee201).
enrolled(s0114, ee202).
enrolled(s0115, ee201).
enrolled(s0115, ee202).
enrolled(s0116, ee201).
enrolled(s0116, ee202).
enrolled(s0117, ee201).
enrolled(s0117, ee202).
enrolled(s0118, ee201).
enrolled(s0118, ee202).
enrolled(s0119, ee201).
enrolled(s0119, ee202).
enrolled(s0120, ee201).
enrolled(s0120, ee202).
