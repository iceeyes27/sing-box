SHELL := /usr/bin/env bash

.PHONY: build test lint check checksum

build:
	bash scripts/build-install.sh

test:
	bash scripts/test.sh

lint:
	bash scripts/lint.sh

check:
	bash scripts/check.sh

checksum:
	bash scripts/checksum.sh
