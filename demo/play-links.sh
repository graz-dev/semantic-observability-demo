#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Prints one ClickHouse Play link per file in demo/queries/. Each link opens the
# query in the browser, ready to run, so nothing has to be pasted into a terminal.
set -euo pipefail

base="${CLICKHOUSE_URL:-http://clickhouse.localhost:8080}"
queries="$(dirname "${BASH_SOURCE[0]}")/queries"

for file in "${queries}"/*.sql; do
  query="$(grep -v -e '^-- Copyright' -e '^-- SPDX' "${file}" | base64 | tr -d '\n')"
  printf '%s\n  %s/play?user=demo&password=demo#%s\n\n' "$(basename "${file}" .sql)" "${base}" "${query}"
done
