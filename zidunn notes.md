# sample data
generate_data.py reads config.toml and generates 2 files: `data.pl` (the full
dataset, including the exam timetable built by timetable.pl) and `data_sample.pl`
(a fixed 20-student test set, not affected by config.toml).

Both the Prolog code and the Python code use data.pl: Python never reads it
directly, it queries Prolog through bridge.py (pyswip), which returns JSON.

Run `make data` (or `python3 generate_data.py --stats`) in the root directory,
with the venv active.


# makefile

makefile is basically a wrapper around the python script. It just gives short names to longer commands you have to type by hand. It doesn't build or compile anything.