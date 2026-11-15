#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Exercise 5: run the same `weaver registry check` the CI job runs, with the
# change that adds an app.customer.tier attribute to the registry.
#
#   demo/policy-check.sh          the registry plus the rejected change
#   demo/policy-check.sh clean    the registry as it is, which passes
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="docker.io/$(grep -o 'otel/weaver[^ ]*' "${repo}/src/telemetry-docs/Dockerfile" | head -1)"

# The copy lives under the repo because Docker Desktop only shares some host paths.
work="$(mktemp -d "${repo}/demo/.policy-check.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
cp -R "${repo}/telemetry-schema/." "${work}/"
if [[ "${1:-}" != "clean" ]]; then
  cp "${repo}/demo/fixtures/customer.yaml" "${work}/attributes/customer.yaml"
fi

docker run --rm -v "${work}:/home/weaver/source:ro" "${image}" \
  registry check -r source -p source/policies
