# Semantic observability workshop

Five self-paced exercises that follow the talk, [DEMO.md](../DEMO.md), on a
local Kubernetes cluster. Each one ends with a checkpoint you can verify.

## What you need

- Docker, with about 6 CPUs and 10 GiB of memory available to it
- [`kind`](https://kind.sigs.k8s.io/), `kubectl` and `helm`
- `make`, `curl` and `python3`

## Start and stop

```bash
make demo-up      # cluster, ClickHouse operator, images, both Helm releases
make demo-down    # delete the cluster
```

The first start pulls about twenty images and builds five of them, so expect
10 to 20 minutes. When it finishes, everything is behind
<http://localhost:8080>:

| Path | What |
|---|---|
| `/` | The web shop |
| `/grafana/`, `/jaeger/ui/` | The usual dashboards and trace viewer |
| `/feature/` | Feature flags, where you inject the failure |
| `/loadgen/` | The load generator that keeps traffic flowing |
| `/telemetry/` | The telemetry schema, published by Weaver |

ClickHouse is not exposed. The queries below run through a port-forward:

```bash
kubectl -n otel-demo-mesh port-forward svc/clickhouse-clickhouse 8123:8123
```

and then in another terminal, for any file in [`queries/`](queries/):

```bash
curl -s -u demo:demo 'http://localhost:8123/?default_format=PrettyCompactMonoBlock' \
  --data-binary @demo/queries/01-error-rate-by-service.sql
```

(Grafana has a ClickHouse data source too, and a dashboard called "Semantic
Observability (ClickHouse)".)

## 1. The swamp

Open `/feature/` and set `paymentFailure` to `25%`. Wait about two minutes.

Try to answer, using Grafana and Jaeger only: across all failures in the last
fifteen minutes, which customer tiers were hit and what is the total order value
at risk?

**Checkpoint:** you cannot, and you can say precisely why. Jaeger has no
`GROUP BY`, Prometheus never saw `loyalty_level`, and the log search has no
trace context.

## 2. One engine

The same Collector has been sending the same data to ClickHouse all along. Run
[`01-error-rate-by-service.sql`](queries/01-error-rate-by-service.sql) and
[`02-failures-by-loyalty-tier.sql`](queries/02-failures-by-loyalty-tier.sql).

**Checkpoint:** every failure sits in the `gold` tier.

## 3. The empty answer

Run [`03-revenue-at-risk.sql`](queries/03-revenue-at-risk.sql).

This repository already contains the fix for what you are about to see. To go
back to the code as the talk starts from, undo it first:

```bash
git apply demo/rehearsal/checkout-before-fix.patch
make demo-checkout
```

Wait a minute for new failures, then run the query again.

**Checkpoint:** it returns `0`, and you can explain why. `checkout` records
`demo.order.amount` only after the charge succeeds, so a failed checkout never
carries it.

## 4. The contract and the fix

Read how the schema describes the problem:

- [`telemetry-schema/services/checkout.yaml`](../telemetry-schema/services/checkout.yaml)
  says `demo.order.amount` is `required`.
- [`telemetry-schema/attributes/order.yaml`](../telemetry-schema/attributes/order.yaml)
  says the order domain depends on `demo.user_context.loyalty_level`.
- <http://localhost:8080/telemetry/> shows the same thing, published.

Now fix `checkout`. In [`src/checkout/main.go`](../src/checkout/main.go), move
the `span.SetAttributes` call that sets `demo.order.id`,
`demo.shipping.amount`, `demo.order.amount` and `demo.order.items.count` to just
after `total` is computed and before `chargeCard`. Only the shipping tracking
id has to stay after the shipment. If you would rather not type it,
`git apply -R demo/rehearsal/checkout-before-fix.patch` puts the fix back.

```bash
make demo-checkout
```

Wait a minute for new failures and run
[`03-revenue-at-risk.sql`](queries/03-revenue-at-risk.sql) again, then
[`05-payoff.sql`](queries/05-payoff.sql).

**Checkpoint:** the number appears, and the payoff query gives revenue at risk
per customer tier.

## 5. Keep the schema true

Two guards, both driven by the registry in
[`telemetry-schema/`](../telemetry-schema/).

Policies, which run in CI before a change can merge:

```bash
demo/act4-policy.sh clean   # the registry as it is: passes
demo/act4-policy.sh         # the same plus app.customer.tier: fails
```

Live-check, which grades real telemetry against the registry. This sends one
span that misspells `demo.user_context.loyalty_level`, then reads the finding
back from ClickHouse:

```bash
demo/act4-live-check.sh
```

Every finding Weaver produces is also queryable, so you can ask which services
are drifting:

```bash
curl -s -u demo:demo 'http://localhost:8123/?default_format=PrettyCompactMonoBlock' \
  --data-binary @demo/queries/04-weaver-findings.sql
```

**Checkpoint:** the policy run fails with `app_prefix_reserved`, and the
live-check run reports `missing_attribute` and `invalid_format` for
`demo.user_context.loyaltyLevel`, both for the reason you expected.

## When something is slow or stuck

- The demo needs a few minutes after `make demo-up` before the load generator
  has produced enough data for the queries.
- On a machine that cannot keep up, set `LOCUST_BROWSER_TRAFFIC_ENABLED` to
  `"false"` in [`chart/otel-demo/values.yaml`](../chart/otel-demo/values.yaml)
  and run `helm upgrade otel-demo chart/otel-demo -n otel-demo`.
- `make demo-down` followed by `make demo-up` always gets you back to a clean
  start.
