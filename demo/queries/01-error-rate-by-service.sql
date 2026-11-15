-- Copyright The OpenTelemetry Authors
-- SPDX-License-Identifier: Apache-2.0

-- Exercise 2: the technical view, the one Grafana already gave you.
-- Same answer as the dashboard, but as SQL it composes.
-- The exporter stores the span status as 'Error', 'Ok' or 'Unset'.
SELECT
    ServiceName,
    countIf(StatusCode = 'Error') AS errors,
    count() AS total,
    round(100 * errors / total, 2) AS error_pct
FROM otel.otel_traces
WHERE Timestamp > now() - INTERVAL 15 MINUTE
GROUP BY ServiceName
ORDER BY error_pct DESC
LIMIT 10;
