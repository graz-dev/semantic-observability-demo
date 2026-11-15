#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Exercise 5: emit one span from a made-up service that misspells
# demo.user_context.loyalty_level as demo.user_context.loyaltyLevel, through the
# same Collector the real services use (through the frontend-proxy OTLP/HTTP
# route on :8080), then read the Weaver live-check finding back from
# ClickHouse (clickhouse.localhost:8080). Needs the cluster from the README to
# be running.
set -euo pipefail

attribute="demo.user_context.loyaltyLevel"
service="loyalty-typo-demo"

trace_id="$(openssl rand -hex 16)"
span_id="$(openssl rand -hex 8)"
now_ns="$(python3 -c 'import time; print(time.time_ns())')"

curl -sf -X POST http://localhost:8080/otlp-http/v1/traces -H 'Content-Type: application/json' -d @- >/dev/null <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"${service}"}}]},
"scopeSpans":[{"scope":{"name":"live-check-demo"},"spans":[{"traceId":"${trace_id}","spanId":"${span_id}",
"name":"charge","kind":1,"startTimeUnixNano":"${now_ns}","endTimeUnixNano":"$((now_ns + 1000000))",
"attributes":[{"key":"${attribute}","value":{"stringValue":"gold"}}]}]}]}]}
JSON
echo "Sent a span from ${service} carrying ${attribute}"

query="SELECT LogAttributes['weaver.finding.id'] AS finding, LogAttributes['weaver.finding.level'] AS level,
  LogAttributes['weaver.finding.context.attribute_key'] AS attribute_key, count() AS findings
FROM otel.otel_logs
WHERE ScopeName = 'weaver.live_check'
  AND LogAttributes['weaver.finding.resource.attribute.service.name'] = '${service}'
GROUP BY finding, level, attribute_key
FORMAT PrettyCompactMonoBlock"

for _ in $(seq 1 30); do
  result="$(curl -s -u demo:demo http://clickhouse.localhost:8080/ --data-binary "${query}")"
  if grep -q "${attribute}" <<<"${result}"; then
    echo "${result}"
    exit 0
  fi
  sleep 2
done
echo "No finding for ${attribute} after 60s" >&2
exit 1
