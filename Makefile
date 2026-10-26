# Local equivalents of the CI jobs. Requires: python3.12+, terraform >= 1.7, tflint, checkov.
PY        ?= .venv/bin/python
TF_DIRS   := terraform/envs/dev terraform/modules/storage terraform/modules/messaging terraform/modules/processor terraform/modules/observability

.PHONY: all venv lint test tf-fmt tf-validate tf-test tflint checkov check

all: check

venv:
	python3 -m venv .venv && $(PY) -m pip install -q -r processor/requirements-dev.txt

lint:
	cd processor && ../$(PY) -m ruff check . && ../$(PY) -m ruff format --check .

test:
	cd processor && ../$(PY) -m pytest

tf-fmt:
	terraform fmt -check -recursive terraform

tf-validate:
	@for d in $(TF_DIRS); do echo "== $$d"; (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate -no-color) || exit 1; done

tf-test: tf-validate
	@for d in $(TF_DIRS); do echo "== $$d"; (cd $$d && terraform test -no-color) || exit 1; done

tflint:
	cd terraform && tflint --init --config "$$PWD/.tflint.hcl" >/dev/null && tflint --recursive --config "$$PWD/.tflint.hcl"

checkov:
	checkov -d terraform --framework terraform --quiet --compact
	checkov -d .github --framework github_actions --quiet --compact

check: lint test tf-fmt tf-test tflint checkov
