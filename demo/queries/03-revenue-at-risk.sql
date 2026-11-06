-- Copyright The OpenTelemetry Authors
-- SPDX-License-Identifier: Apache-2.0

-- Act 2, Query 3: the question that cannot be answered yet.
-- Returns 0 before the Act 3 fix: checkout only records demo.order.amount after
-- the charge succeeds, so failed checkouts never carry it.
WITH failed AS (
    SELECT DISTINCT TraceId
    FROM otel.otel_traces
    WHERE ServiceName = 'payment'
      AND StatusCode = 'Error'
      AND Timestamp > now() - INTERVAL 15 MINUTE
)
SELECT
    count() AS lost_orders,
    round(sum(toFloat64OrZero(SpanAttributes['demo.order.amount'])), 2) AS revenue_at_risk
FROM otel.otel_traces
WHERE TraceId IN (SELECT TraceId FROM failed)
  AND SpanAttributes['demo.order.amount'] != ''
  AND Timestamp > now() - INTERVAL 15 MINUTE;
