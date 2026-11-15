-- Copyright The OpenTelemetry Authors
-- SPDX-License-Identifier: Apache-2.0

-- Exercise 2: one question across all three signals.
-- Traces say which payments failed and for which tier. The logs of those same
-- traces say what the service reported, joined on TraceId. The payment counter
-- (demo.payment.transactions, only incremented after a successful charge) gives
-- the payments that went through, so the failure rate is measured, not guessed.
-- The counter is cumulative, so the payments in the window are the growth of
-- each series between its first and last sample, or its last value if the
-- series started inside the window.
WITH
failed AS (
    SELECT DISTINCT
        TraceId,
        SpanAttributes['demo.user_context.loyalty_level'] AS tier
    FROM otel.otel_traces
    WHERE ServiceName = 'payment'
      AND StatusCode = 'Error'
      AND SpanAttributes['demo.user_context.loyalty_level'] != ''
      AND Timestamp > now() - INTERVAL 15 MINUTE
),
succeeded AS (
    SELECT sum(delta) AS n
    FROM (
        SELECT max(Value) - if(min(StartTimeUnix) > now() - INTERVAL 15 MINUTE, 0, min(Value)) AS delta
        FROM otel.otel_metrics_sum
        WHERE MetricName = 'demo.payment.transactions'
          AND TimeUnix > now() - INTERVAL 15 MINUTE
        GROUP BY ResourceAttributes, Attributes
    )
)
SELECT
    (SELECT count() FROM failed) AS failed_payments,
    (SELECT n FROM succeeded) AS successful_payments,
    round(100 * failed_payments / (failed_payments + successful_payments), 1) AS failure_pct,
    (SELECT any(tier) FROM failed) AS tier,
    topK(1)(l.Body)[1] AS what_the_logs_say,
    count() AS log_lines
FROM otel.otel_logs AS l
WHERE l.TraceId IN (SELECT TraceId FROM failed)
  AND l.SeverityNumber >= 13
  AND l.Timestamp > now() - INTERVAL 15 MINUTE;
