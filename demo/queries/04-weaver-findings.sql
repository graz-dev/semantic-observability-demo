-- Copyright The OpenTelemetry Authors
-- SPDX-License-Identifier: Apache-2.0

-- Exercise 5: schema violations as telemetry. Weaver live-check findings land in
-- otel_logs under the weaver.live_check scope.
SELECT
    LogAttributes['weaver.finding.id'] AS finding,
    LogAttributes['weaver.finding.context.attribute_key'] AS attribute_key,
    LogAttributes['weaver.finding.resource.attribute.service.name'] AS service,
    count() AS findings
FROM otel.otel_logs
WHERE ScopeName = 'weaver.live_check'
  AND LogAttributes['weaver.finding.level'] = 'violation'
  AND Timestamp > now() - INTERVAL 15 MINUTE
GROUP BY finding, attribute_key, service
ORDER BY findings DESC
LIMIT 25;
