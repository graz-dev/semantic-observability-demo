#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Act 4, beat 2: run the same `weaver registry check` the CI job runs, with the
# rehearsal PR (an app.customer.tier attribute) added to the registry.
#
#   demo/act4-policy.sh          the registry plus the rejected change
#   demo/act4-policy.sh clean    the registry as it is, which passes
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="docker.io/$(grep -o 'otel/weaver[^ ]*' "${repo}/src/telemetry-docs/Dockerfile" | head -1)"

# The copy lives under the repo because Docker Desktop only shares some host paths.
work="$(mktemp -d "${repo}/demo/.act4.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
cp -R "${repo}/telemetry-schema/." "${work}/"
if [[ "${1:-}" != "clean" ]]; then
  cp "${repo}/demo/rehearsal/customer.yaml" "${work}/attributes/customer.yaml"
fi

docker run --rm -v "${work}:/home/weaver/source:ro" "${image}" \
  registry check -r source -p source/policies
