# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


# All documents to be used in spell check.
ALL_DOCS := $(shell find . -type f -name '*.md' -not -path './.github/*' -not -path '*/node_modules/*' -not -path '*/_build/*' -not -path '*/deps/*' -not -path */Pods/* -not -path */.expo/* | sort)
PWD := $(shell pwd)

TOOLS_DIR := ./internal/tools
MISSPELL_BINARY=bin/misspell
MISSPELL = $(TOOLS_DIR)/$(MISSPELL_BINARY)
ADDLICENSE_BINARY=bin/addlicense
ADDLICENSE = $(TOOLS_DIR)/$(ADDLICENSE_BINARY)

DOCKER_CMD ?= docker

# Accept either `service=` or `SERVICE=` for single-service targets.
# Must be evaluated at file scope; an `ifdef SERVICE` block inside a recipe is a shell command,
# not a Make conditional, so the alias never takes effect there.
ifdef SERVICE
service := $(SERVICE)
endif


# see https://github.com/open-telemetry/build-tools/releases for semconvgen updates
# Keep links in semantic_conventions/README.md and .vscode/settings.json in sync!
SEMCONVGEN_VERSION=0.11.0
YAMLLINT_VERSION=1.30.0

.PHONY: all
all: install-tools markdownlint misspell yamllint

$(MISSPELL):
	cd $(TOOLS_DIR) && go build -o $(MISSPELL_BINARY) github.com/client9/misspell/cmd/misspell

$(ADDLICENSE):
	cd $(TOOLS_DIR) && go build -o $(ADDLICENSE_BINARY) github.com/google/addlicense

.PHONY: misspell
misspell:	$(MISSPELL)
	$(MISSPELL) -error $(ALL_DOCS)

.PHONY: misspell-correction
misspell-correction:	$(MISSPELL)
	$(MISSPELL) -w $(ALL_DOCS)

.PHONY: markdownlint
markdownlint:
	@if ! npm ls markdownlint; then npm install; fi
	@for f in $(ALL_DOCS); do \
		echo $$f; \
		npx --no -p markdownlint-cli markdownlint -c .markdownlint.yaml $$f \
			|| exit 1; \
	done

.PHONY: install-yamllint
install-yamllint:
    # Using a venv is recommended
	yamllint --version >/dev/null 2>&1 || pip install -U yamllint~=$(YAMLLINT_VERSION)

.PHONY: yamllint
yamllint: install-yamllint
	yamllint .

.PHONY: checklicense
checklicense:	$(ADDLICENSE)
	@echo "Checking license headers..."
	$(ADDLICENSE) -check -c "The OpenTelemetry Authors" -l apache -s=only -y "" \
		-ignore node_modules/** \
		-ignore .expo/** \
		-ignore Pods/** \
		-ignore **/extras/** \
		-ignore **/vendor/** \
		-ignore **/.venv/** \
		-ignore **/dist/** \
		-ignore **/build/** \
		-ignore **/*_pb2.py \
		-ignore **/*_pb2_grpc.py \
		-ignore **/genproto/** \
		-ignore **/protos/*.ts \
		.

.PHONY: addlicense
addlicense:	$(ADDLICENSE)
	@echo "Adding license headers..."
	$(ADDLICENSE) -c "The OpenTelemetry Authors" -l apache -s=only -y "" \
		-ignore node_modules/** \
		-ignore .expo/** \
		-ignore Pods/** \
		-ignore **/extras/** \
		-ignore **/vendor/** \
		-ignore **/.venv/** \
		-ignore **/dist/** \
		-ignore **/build/** \
		-ignore **/*_pb2.py \
		-ignore **/*_pb2_grpc.py \
		-ignore **/genproto/** \
		-ignore **/protos/*.ts \
		.

.PHONY: checklinks
checklinks:
	@echo "Checking links..."
	lychee --config .lychee.toml --cache .

# Run all checks in order of speed / likely failure.
.PHONY: check
check: misspell markdownlint checklicense checklinks
	@echo "All checks complete"

# Attempt to fix issues / regenerate tables.
.PHONY: fix
fix: misspell-correction
	@echo "All autofixes complete"

.PHONY: install-tools
install-tools: $(MISSPELL) $(ADDLICENSE)
	npm install
	@echo "All tools installed"

.PHONY: generate-protobuf
generate-protobuf:
	./scripts/ide-gen-proto.sh

.PHONY: docker-generate-protobuf
docker-generate-protobuf:
	./scripts/docker-gen-proto.sh

.PHONY: clean
clean:
	rm -rf ./src/{checkout,product-catalog}/genproto/oteldemo/
	rm -rf ./src/recommendation/{demo_pb2,demo_pb2_grpc}.py
	rm -rf ./src/frontend/protos/demo.ts

.PHONY: check-clean-work-tree
check-clean-work-tree:
	@if ! git diff --quiet; then \
	  echo; \
	  echo 'Working tree is not clean, did you forget to run "make docker-generate-protobuf"?'; \
	  echo; \
	  git status; \
	  exit 1; \
	fi

# Orchestration targets (build, start, stop, redeploy, tests) run entirely on
# Kubernetes now — see PLAN.md for the Helm/kind setup that replaces the old
# docker-compose targets. They land here once that work is implemented.
