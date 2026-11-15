-- Copyright The OpenTelemetry Authors
-- SPDX-License-Identifier: Apache-2.0

-- Exercise 2: the reveal.
-- One GROUP BY on a business attribute turns "5% errors" into "we are only
-- failing our best customers".
-- The attribute lives on the span payment creates for the charge, not on the
-- gRPC server span above it, so rows without a tier are filtered out.
SELECT
    SpanAttributes['demo.user_context.loyalty_level'] AS loyalty_tier,
    countIf(StatusCode = 'Error') AS failed,
    count() AS total
FROM otel.otel_traces
WHERE ServiceName = 'payment'
  AND SpanAttributes['demo.user_context.loyalty_level'] != ''
  AND Timestamp > now() - INTERVAL 15 MINUTE
GROUP BY loyalty_tier
ORDER BY failed DESC;
