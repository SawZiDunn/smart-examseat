# SmartExamSeat - convenience targets
PY ?= python3

.PHONY: help data workbooks test test-prolog test-python run run-sample demo term clean

help:
	@echo "make data         regenerate data.pl (from datasets/big.xlsx) and data_sample.pl"
	@echo "make workbooks    remake datasets/big.xlsx and small.xlsx from their recipes"
	@echo "make test         run both test suites"
	@echo "make test-prolog  run the plunit suite"
	@echo "make test-python  run the bridge / UI / export tests"
	@echo "make run          start the web UI (import a workbook in the browser)"
	@echo "make run-sample   start the web UI on the 20-student sample"
	@echo "make demo         solve every session from the console"
	@echo "make term         seat the whole term and print coverage per cohort"
	@echo "make clean        remove generated output"

data:
	$(PY) generate_data.py --stats

workbooks:
	$(PY) workbook.py datasets/big.toml datasets/big.xlsx
	$(PY) workbook.py datasets/small.toml datasets/small.xlsx

test: test-prolog test-python

test-prolog:
	swipl -q -g run_tests -t halt tests/test_prolog.pl

test-python:
	$(PY) -m unittest discover -s tests -v

run:
	$(PY) app.py

run-sample:
	$(PY) app.py --dataset data_sample.pl

demo:
	swipl -q -g demo -t halt demo.pl

term:
	swipl -q -g print_term_report -t halt main.pl

clean:
	rm -rf out/* __pycache__ tests/__pycache__
