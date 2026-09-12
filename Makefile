.PHONY: help all setup deps build fmt fmt-check lint test python-check python-tests coverage ci dialyzer e2e

MIX ?= ./scripts/mix-gate

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

python-check:
	@python3 -c 'import sys; sys.exit("make all: Python 3.11+ ist für die vollständige Testmatrix erforderlich") if sys.version_info < (3, 11) else None'

python-tests: python-check
	python3 -m unittest discover -s test/linear_app -v

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci: python-check
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) python-tests
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
