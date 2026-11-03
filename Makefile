SHELL := bash
ARGS ?=

.DEFAULT_GOAL := help

.PHONY: help validate lint sync dry-run check-sources scan report clean

help:
	@printf '%s\n' \
	  'validate       validate manifests and configuration' \
	  'lint           run shellcheck over scripts/' \
	  'sync           mirror every pinned image (ARGS="--category networking")' \
	  'dry-run        print the plan without touching a registry' \
	  'check-sources  resolve upstream sources and assert platforms' \
	  'scan           scan every mirrored image with Trivy' \
	  'report         render .results/*.jsonl as Markdown' \
	  'clean          remove .results/'

validate:
	./scripts/validate.sh

lint:
	shellcheck scripts/*.sh

sync:
	./scripts/sync.sh $(ARGS)

dry-run:
	./scripts/sync.sh --dry-run $(ARGS)

check-sources:
	./scripts/sync.sh --check-sources $(ARGS)

scan:
	./scripts/scan.sh --all

report:
	./scripts/generate-report.sh

clean:
	rm -rf .results
