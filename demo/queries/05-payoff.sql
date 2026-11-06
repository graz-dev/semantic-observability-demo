-- Copyright The OpenTelemetry Authors
-- SPDX-License-Identifier: Apache-2.0

-- Act 5: the payoff. One query, no tribal knowledge, a business answer.
-- The loyalty tier is recorded on payment's span and the order amount on
-- checkout's (after the Act 3 fix, on failures too), so the two are joined on
-- the trace they share.
SELECT
    tier,
    count() AS failed_orders,
    round(sum(amount), 2) AS revenue_at_risk
FROM (
    SELECT
        TraceId,
        maxIf(SpanAttributes['demo.user_context.loyalty_level'],
              SpanAttributes['demo.user_context.loyalty_level'] != '') AS tier,
        maxIf(toFloat64OrZero(SpanAttributes['demo.order.amount']),
              SpanAttributes['demo.order.amount'] != '') AS amount,
        countIf(ServiceName = 'checkout' AND StatusCode = 'Error') AS checkout_errors
    FROM otel.otel_traces
    WHERE ServiceName IN ('checkout', 'payment')
      AND Timestamp > now() - INTERVAL 15 MINUTE
    GROUP BY TraceId
    HAVING checkout_errors > 0
)
GROUP BY tier
ORDER BY revenue_at_risk DESC;
