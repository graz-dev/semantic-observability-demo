# Semantic observability demo

Companion demo for the talk *Beyond the Data Swamp: Building Your Semantic
Observability Mesh*.

Most engineering teams are drowning in logs, metrics and traces, and still feel
blind when something fails. The problem is not a lack of data but a lack of
shared understanding. This demo shows, on one running system, how to go from
"the payment service has errors" to "every failed checkout was a gold-tier
customer, worth this much", with three things:

- **ClickHouse**, one engine for all the telemetry, queried with SQL;
- **a semantic layer**, your own OpenTelemetry conventions, owned per domain;
- **Weaver**, which validates that schema in CI and against live telemetry.

Everything runs on this fork of the OpenTelemetry Demo, on a local Kubernetes
cluster. You can read this document as the script of a 20 minute talk, or follow
the five exercises in [the walkthrough](#the-walkthrough) on your own machine.
Each exercise ends with a checkpoint you can verify.

## What you need

- Docker, with about 6 CPUs and 10 GiB of memory available to it
- [`kind`](https://kind.sigs.k8s.io/), `kubectl` and `helm`
- `make`, `curl`, `openssl` and `python3`
- a browser. Port 8080 on your machine must be free.

## Start and stop

This repository already contains the fix for the problem the demo is about; you
will write it yourself in exercise 4. To start from the code as the talk starts
from it, undo the fix first, then start the demo:

```bash
git apply demo/fixtures/checkout-before-fix.patch
make demo-up      # cluster, ClickHouse operator, images, both Helm releases
```

When you are done:

```bash
make demo-down    # delete the cluster
```

`make demo-up` is one command: the `kind` cluster, the ClickHouse operator, the
images this fork builds, and both Helm releases. The first start pulls about
twenty images and builds five of them, so expect 10 to 20 minutes. When it
finishes, everything is behind <http://localhost:8080>:

| Path | What |
|---|---|
| `/` | The web shop |
| `/grafana/`, `/jaeger/ui/` | The usual dashboards and trace viewer |
| `/feature/` | Feature flags, where you inject the failure |
| `/loadgen/` | The load generator that keeps traffic flowing |
| `/telemetry/` | The telemetry schema, published by Weaver |

ClickHouse has its own name on the same port, <http://clickhouse.localhost:8080>
(`*.localhost` resolves to your machine, so there is nothing to configure). Its
built-in SQL client lives at `/play`, with user `demo` and password `demo`.
Print a link for each file in [`queries/`](queries/) that opens it ready to run:

```bash
demo/play-links.sh
```

The files in `queries/` are the SQL used in the walkthrough. From a terminal,
the same endpoint takes plain HTTP:

```bash
curl -s -u demo:demo 'http://clickhouse.localhost:8080/?default_format=PrettyCompactMonoBlock' \
  --data-binary @demo/queries/01-error-rate-by-service.sql
```

Grafana has a ClickHouse data source too, and a dashboard called "Semantic
Observability (ClickHouse)". The queries look at the last fifteen minutes, so
give the demo a few minutes after it starts before you run them.

---

## The idea, for someone who has never heard of observability

Read this section even if you know OTel. The demo is built to land these five
points in order, and every command below exists to serve one of them.

### What telemetry is

While your software runs, every part of it writes down what it just did: *"I
received a request"*, *"I called the payment service"*, *"it took 300 ms"*,
*"it failed"*. Those notes are **telemetry**. They come in three shapes:

- **traces** — the step-by-step story of one single user request as it travels
  across services,
- **metrics** — numbers counted over time (requests per second, error rate),
- **logs** — free-form text lines a service prints.

Modern systems produce staggering amounts of all three, and storing them is one
of the larger line items on an engineering budget.

### Why more data has not made us less blind

Telemetry is almost always written in **technical** vocabulary:
`service=payment`, `status=ERROR`, `p99=2.3s`. So when something breaks, you can
see *what* broke. You cannot answer the questions that anyone actually asks in
an incident review:

> Which customers did we affect? How much money did we lose? Were they ordinary
> customers or our most valuable ones? Is this worth waking someone up for?

To answer those today, an engineer opens three different tools, correlates by
hand, exports to a spreadsheet, and estimates. That is the **data swamp**: all
the data, none of the answers.

### The three things that are actually broken

The swamp is not one problem, it is three, and they need three different fixes.

1. **The data is physically split.** Traces live in one database, metrics in a
   second, logs in a third. There is no way to ask a single question that spans
   all three.
2. **There is no shared vocabulary.** One team writes `user_id`, another
   `userId`, a third `customer.identifier`. Same concept, three spellings — so
   nothing can be joined or aggregated across teams.
3. **There is no business meaning, and no guarantee.** Nobody ever wrote down
   that a concept like "customer loyalty tier" exists, which values it may take,
   which team owns it, or which services are *required* to emit it. So it is
   present sometimes and missing others, and nobody trusts it enough to build
   on.

### The three-part fix

| Broken thing | Fix | What it gives you |
|---|---|---|
| Data physically split, and expensive | **ClickHouse** — one columnar store for all signals, queried with SQL | One question can touch traces, logs and metrics at once, at a fraction of the cost |
| No shared vocabulary | **A semantic layer** — your own OpenTelemetry conventions, owned per domain | Every team spells the same concept the same way, so data joins |
| No meaning, no guarantee | **Weaver** — validates the schema in CI, enforces house rules, and checks the *real running telemetry* against it | The vocabulary is true, not aspirational |

The **mesh** is the shape of the second one: each domain team owns its slice of
the vocabulary and publishes it into a shared registry, so every other team can
discover it and depend on it. Central standard, distributed ownership.

### The payoff, in one sentence

You go from *"the payment service has a 5% error rate"* to *"every failed
checkout in the last hour was a gold-tier customer, worth €12,400 in orders"* —
with one query instead of three tools and an afternoon.

---

## The incident we use, and why it is perfect

We drive the whole demo with one fault, injected at runtime through flagd with
no rebuild: **`paymentFailure`**.

Two properties of this codebase make it an unusually good vehicle. Both are
already in the upstream demo; we did not plant them.

### It fails along a business dimension, not a technical one

In [`src/payment/charge.js:42-48`](../src/payment/charge.js#L42-L48), the
injected failure is stamped with `demo.user_context.loyalty_level = gold`:

```js
if (numberVariant > 0) {
  // n% chance to fail with demo.user_context.loyalty_level=gold
  if (Math.random() < numberVariant) {
    span.setAttributes({'demo.user_context.loyalty_level': 'gold' });
    throw new Error('Payment request failed. Invalid token. ...');
  }
}
```

On a technical dashboard this looks like uniform random noise. Sliced by one
business attribute, it is *"you are losing your best customers, and only your
best customers"*. Same bytes, completely different conclusion. That is the
thesis of the talk, already sitting in the demo.

### The number you need is only recorded on the happy path

In [`src/checkout/main.go`](../src/checkout/main.go), the order attributes,
including `demo.order.amount`, are set only after the charge succeeds. When
payment fails, checkout returns early and the order value is never recorded at
all. The committed code already has this fixed; the patch you applied in
[Start and stop](#start-and-stop) takes it back to the code as the talk starts
from it.

This is the single most valuable beat in the demo, because it is a completely
real and extremely common bug:

> The data you need to size the business impact is only written on the happy
> path. It goes missing exactly when you need it.

It also gives the exercises genuine causal necessity rather than a decorative
progression:

- **Exercise 1 (silos):** you cannot even ask the question.
- **Exercise 2 (ClickHouse):** you can ask it, and you get *half* an answer. You
  discover the failures are all gold-tier. But "how much money" comes back
  empty, proving that a fast engine alone is not enough.
- **Exercises 4 and 5 (semantic layer and Weaver):** you define the contract,
  the attribute moves to where the contract says it must be, and live-check
  proves every service now honours it. The query finally returns the number.

---

## How it fits together

```
kind cluster (1 control-plane + 2 workers)
├── namespace: otel-demo       the webstore app, load generator, flagd, the
│                               OTel Collector, and Jaeger/Prometheus/Grafana/
│                               OpenSearch: one Helm release, deployed as
│                               the official chart normally would
└── namespace: otel-demo-mesh  ClickHouse and Weaver live-check: what this
                                talk adds, kept deliberately separate
```

Cross-namespace DNS just works, so **the same Collector fans out to
Jaeger/Prometheus/OpenSearch and to `otel-demo-mesh` concurrently, all the
time.** Nothing is switched off between exercises: it is the same live data,
seen through a different lens.

```
services ──▶ OTel Collector ──┬──▶ Jaeger / Prometheus / OpenSearch   (otel-demo)
              (otel-demo)     └──▶ ClickHouse                          (otel-demo-mesh)
                               └──▶ Weaver live-check ──▶ findings as OTLP logs ──▶ ClickHouse
```

ClickHouse is managed by the Altinity Kubernetes Operator through a single
`ClickHouseInstallation` named `clickhouse`. The Collector writes to it over the
native protocol, and the schema is created by an init script before the first
byte arrives.

There is no Ingress and no Gateway API. `frontend-proxy` (Envoy) already does
the path-based routing the demo needs, so `kind` maps host port 8080 straight to
a `NodePort` on its Service. Envoy also sends requests whose `Host` is
`clickhouse.localhost` to ClickHouse's HTTP interface. The port is bound to
`127.0.0.1` in `kind/cluster.yaml`, so none of this is reachable from the
network.

---

## The walkthrough

### 1. The swamp

Open <http://localhost:8080/feature/> and set `paymentFailure` to `25%`. Wait
about five minutes for enough signal.

Now investigate it the way a normal team does:

1. **Grafana**: the error rate on `payment` climbs. You know *something* is
   wrong.
2. **Jaeger**: filter for failed traces on `payment`. You can open one trace and
   read `demo.user_context.loyalty_level = gold` on the span. **One** trace.
3. **Logs**: in Grafana, Explore, with the OpenSearch data source, find the
   matching log line by pasting the trace ID.

Then ask the business question:

> Across all failures in the last fifteen minutes, which customer tiers were
> hit, and what is the total order value at risk?

And try to answer it. Jaeger has no `GROUP BY`; it is a trace viewer, not an
analytics engine. Prometheus never saw `loyalty_level`, because putting a
high-cardinality business attribute into metric labels is exactly what you are
told never to do. OpenSearch has some of it, in a third query language, without
the trace context.

The point: the problem is not missing data. Every byte you need was collected.
The problem is that there is no surface on which the question can be asked, and
no shared vocabulary in which to ask it.

**Checkpoint:** you cannot, and you can say precisely why. Jaeger has no
`GROUP BY`, Prometheus never saw `loyalty_level`, and the log search has no
trace context.

### 2. One engine

The same Collector that fed Jaeger, Prometheus and OpenSearch has been exporting
to ClickHouse the whole time. You are about to look at the exact same live data
through a different lens.

Look at the `clickhouse` exporter block in
[`chart/otel-demo/values.yaml`](../chart/otel-demo/values.yaml), then at the
tables in the `otel` database (`SHOW TABLES FROM otel` in the SQL client):

```
otel_traces                          otel_metrics_gauge
otel_traces_trace_id_ts              otel_metrics_sum
otel_traces_trace_id_ts_mv           otel_metrics_histogram
otel_logs                            otel_metrics_exponential_histogram
                                     otel_metrics_summary
```

Nobody designed this schema, and there is no ETL job. It is the exporter's own,
unmodified apart from the database name and a 24 hour TTL, applied as a
ClickHouse init script (`chart/otel-demo-mesh/files/otel-schema.ddl`, with
`create_schema: false` in the Collector). Every one of those is an ordinary
MergeTree table, so all three signals are joinable with plain SQL from the
first minute.

Run [`01-error-rate-by-service.sql`](queries/01-error-rate-by-service.sql): the
technical view, the one Grafana already gave you. Same answer, but now it is
SQL, so it composes.

Run
[`02-failures-by-loyalty-tier.sql`](queries/02-failures-by-loyalty-tier.sql):
the reveal. Every single failure sits in `gold`. One `GROUP BY` on a business
attribute turned "some errors" into "we are only failing our best customers".
(The `!= ''` filter matters: payment also emits a gRPC server span that carries
the error but not the tier, and without the filter it shows up as a blank row.)

Then run [`06-correlation.sql`](queries/06-correlation.sql), one question across
all three signals. Because every signal is an ordinary table in the same
database, one statement can read all three. The failed payments come from
traces, what those same requests logged comes from joining logs on `TraceId`,
and the payments that went through come from the payment counter. Together they
give a measured failure rate, and the logs of the failed payments say why they
failed. Traces and logs share a real key; metrics have none, so they are tied in
by service and time window.

A note on cost: columnar storage plus compression makes the high-cardinality
business attributes (user IDs, order IDs, loyalty tiers) the kind of thing you
can now afford to keep, precisely the data that a metrics system forces you to
throw away.

**Checkpoint:** every failure sits in the `gold` tier.

### 3. The empty answer

Run [`03-revenue-at-risk.sql`](queries/03-revenue-at-risk.sql).

**It returns zero.** Not because ClickHouse failed, but because
`demo.order.amount` is written after the charge succeeds, so failed checkouts
never record it. Do not fix this yet. The honest conclusion:

> A fast, cheap, unified engine bought us the ability to *ask*. It did not buy
> us the ability to *answer*. That takes meaning, and meaning has to be
> designed.

**Checkpoint:** it returns `0`, and you can explain why.

If it returns a number, failures were produced with the fix in place: you
started the demo without applying the patch in
[Start and stop](#start-and-stop), or you injected the failure before. To get to
zero, apply the patch, run `make demo-checkout` to redeploy `checkout`, and wait
fifteen minutes, until the failures from before leave the window of the
queries.

### 4. The contract and the fix

Start from the tribal-knowledge problem: those queries only worked because
whoever wrote them knew the attribute is spelled
`demo.user_context.loyalty_level` and lives on the `payment` span. Nobody else
in a company knows that unless it is written down somewhere a person or a tool
can find. In this repository it is:

```
telemetry-schema/
├── manifest.yaml          # the registry: version, semconv dependency
├── attributes/            # vocabulary, grouped by business domain
│   ├── user.yaml          #   demo.user_context.loyalty_level lives here
│   ├── order.yaml
│   └── payment.yaml
├── metrics/               # metric definitions, per service
├── services/              # what each service declares it emits
└── policies/              # house rules, written in Rego
```

Open [`attributes/user.yaml`](../telemetry-schema/attributes/user.yaml) and read
one definition: key, type, brief, stability, examples. That is a vocabulary
entry, a business concept given a single official spelling, a type and a
meaning. Then open
[`services/payment.yaml`](../telemetry-schema/services/payment.yaml): the
payment service *declares* which attributes it emits. That is a contract, not
documentation. The same thing, published as a browsable site generated by
Weaver, is at <http://localhost:8080/telemetry/>.

It is also a mesh. Every attribute names an owning domain (`annotations.owner`)
and a domain can declare what it depends on (`annotations.depends_on`). Both are
visible on the published pages, and the policies in exercise 5 enforce them:

- the **user** domain owns `demo.user_context.loyalty_level` and is accountable
  for it;
- the **order** domain *depends on* it:
  [`order.yaml`](../telemetry-schema/attributes/order.yaml) lists it under
  `demo.order.amount`, because order-value analysis is meaningless without
  customer tier;
- payment must not invent its own user attribute, yet today it literally does,
  by randomising a loyalty level inside the payment service
  ([`charge.js:65`](../src/payment/charge.js#L65)). That is a domain boundary
  violation that the policies do not catch yet, and where [the loyalty tier
  question](#where-this-goes-next) comes from.

Now fix the empty result, driven by the contract.
[`services/checkout.yaml`](../telemetry-schema/services/checkout.yaml) says
`demo.order.amount` is `required` on every checkout attempt, success or failure.
In [`src/checkout/main.go`](../src/checkout/main.go), move the
`span.SetAttributes` call that sets `demo.order.id`, `demo.shipping.amount`,
`demo.order.amount` and `demo.order.items.count` to just after `total` is
computed and before `chargeCard`. Only the shipping tracking id has to stay
after the shipment. If you would rather not type it,
`git apply -R demo/fixtures/checkout-before-fix.patch` puts the fix back.

```bash
make demo-checkout
```

Wait about five minutes for new failures (the load generator produces only a few
payments a minute, so failures are sparse) and run
[`03-revenue-at-risk.sql`](queries/03-revenue-at-risk.sql) again. If it still
shows `0`, no failure has happened since the redeploy: wait a little and run it
again. Then run
[`05-payoff.sql`](queries/05-payoff.sql): one query, no tribal knowledge, a
business answer. The tier is recorded on payment's span and the amount on
checkout's, so the query joins them on the trace they share. Failures from
before the fix still have no amount and count as lost orders in the payoff query
until they leave the fifteen minute window; only the new ones carry a value.

The code change is four lines. The reason anyone knew to make it is the
contract.

**Checkpoint:** the number appears, and the payoff query gives revenue at risk
per customer tier.

### 5. Keep the schema true

Two guards, both driven by the registry in
[`telemetry-schema/`](../telemetry-schema/). The background is in
[Weaver, explained from zero](#weaver-explained-from-zero).

**Policies**, which run in CI before a change can merge (the `weaver-check` job
in [`checks.yml`](../.github/workflows/checks.yml)). The house rules live in
[`policies/attributes.rego`](../telemetry-schema/policies/attributes.rego):
every demo attribute must use the `demo.` prefix, never `app.`; every attribute
must name an owning domain that matches its file; and `depends_on` must point at
something that exists. This needs Docker and pulls the Weaver image the first
time:

```bash
demo/policy-check.sh clean   # the registry as it is: passes
demo/policy-check.sh         # the same plus app.customer.tier: fails
```

The change that gets rejected is
[`fixtures/customer.yaml`](fixtures/customer.yaml). Weaver prints a long list of
"not yet stable" warnings first; the result is at the top for the passing run
and at the bottom for the failing one. This is how a vocabulary stays *one*
vocabulary as an organisation grows.

**Live-check**, which grades real telemetry against the registry: the strongest
beat. A copy of the live OTLP stream is forked into Weaver, which grades what
really arrives in real time. This sends one span from a made-up service that
misspells `demo.user_context.loyalty_level`, then reads the finding back from
ClickHouse, a few seconds later, something no amount of code review would have
caught:

```bash
demo/live-check.sh
```

Live-check runs with `--emit-otlp-logs` pointed back at the Collector, so every
finding it produces lands in ClickHouse as telemetry, and governance becomes a
queryable dashboard: *which teams are drifting from the standard, and by how
much*. Ask it with
[`04-weaver-findings.sql`](queries/04-weaver-findings.sql). Most of what you see
comes from upstream attributes the demo apps still emit under deprecated names,
such as `http.status_code`; add
`AND LogAttributes['weaver.finding.context.attribute_key'] LIKE 'demo.%'` to the
`WHERE` clause to look at this registry's own vocabulary.

**Checkpoint:** the policy run fails with `app_prefix_reserved`, and the
live-check run reports `missing_attribute` and `invalid_format` for
`demo.user_context.loyaltyLevel`, both for the reason you expected.

The swamp was never a storage problem. It was a **meaning** problem, and meaning
is something you design, publish and enforce, exactly like an API.

---

## Weaver, explained from zero

This is the background for exercise 5, written for someone who has never heard
of OpenTelemetry.

### What problem Weaver solves

Say your company agrees that customer tier will always be recorded as
`demo.user_context.loyalty_level`, a string, one of `gold`/`silver`/`bronze`.
You write that on a wiki page.

Six months later: one team ships `loyaltyLevel`, another ships
`user.tier`, a third emits `GOLD` in uppercase, and a fourth stopped emitting it
entirely during a refactor. Every dashboard built on that attribute is now
quietly wrong. Nobody noticed, because nothing was checking.

**Weaver is the tool that checks.** The mental model: *a compiler and test suite
for your telemetry vocabulary*. You describe the vocabulary once, in YAML, and
Weaver turns it into something enforceable.

### What a registry is

A **semantic convention registry** is a folder of YAML files describing every
attribute, metric and signal your systems are allowed to emit. Ours is
[`telemetry-schema/`](../telemetry-schema/). One entry looks like this:

```yaml
- key: demo.user_context.loyalty_level
  type: string
  brief: Customer loyalty level
  stability: stable
  note: The loyalty tier of the customer making the payment.
  examples: ["gold", "platinum", "silver", "bronze"]
```

It is the wiki page, except machine-readable — so tools can act on it.

Our registry also declares a dependency on the official OpenTelemetry semantic
conventions (`manifest.yaml`, `semconv_version: 1.40.0`). This is what "extend,
don't reinvent" means in practice: standard concepts like `user.id` and
`http.request.method` come from upstream, and we only define what is genuinely
specific to our business, under a `demo.` prefix.

### The four things Weaver does with it

#### `weaver registry check` — is the vocabulary itself sound?

Parses every YAML file, resolves references and `extends` clauses, and fails if
anything is broken: a service referencing an attribute that does not exist, a
duplicate key, a malformed type, a missing required field.

Analogy: **the compiler**. It does not know whether your code is correct, but it
guarantees the vocabulary is internally consistent and every reference resolves.

Already running in CI here — a PR that references an undefined attribute cannot
merge.

#### Rego policies — your own house rules

`check` enforces *OpenTelemetry's* rules. Rego policies let you add **yours**,
written as small logic rules that run against the resolved registry.

Rules worth demoing:

- every custom attribute must start with `demo.` and never `app.` (which is
  reserved for client-side instrumentation — this is a real rule in
  [AGENTS.md](../AGENTS.md)),
- every attribute must declare an owning domain,
- no attribute may duplicate a concept upstream semconv already defines,
- an attribute marked `stable` may never change type.

Analogy: **the linter with your team's style guide**. `check` is the language;
Rego is your organisation's rules on top of it.

The demo moment is a PR adding `app.customer.tier` being rejected by CI with a
readable explanation. That is governance that scales without a review
bottleneck.

#### `weaver registry live-check` — does reality match the schema?

The other three operate on YAML. This one operates on **your actual running
telemetry**.

Weaver opens an OTLP listener, you fork a copy of your live traffic into it, and
it grades what really arrives against the registry, streaming findings as they
come. It reports:

- attributes emitted by real services that are **not in the registry at all**
  (someone invented a name),
- attributes whose **type or value** does not match the definition,
- required attributes that are **missing**,
- names that violate conventions — including near-misses like `loyaltyLevel`
  against a registered `loyalty_level`, which is where most real drift hides.

Analogy: **integration tests for your telemetry**, running against production
traffic rather than a fixture.

This is the piece that turns the registry from documentation into a guarantee,
and it is the answer to the abstract's promise that *"your systems all speak the
same language"* — because it is the only one of the four that can actually prove
they do.

Two flags worth showing: `--fail-on violation` (so it can gate a pipeline) and
`--emit-otlp-logs` (so findings flow back into your observability stack as
telemetry, which is how you get the governance dashboard in exercise 5).

#### `weaver registry generate` — publish it

Renders the registry through templates into whatever artefact you need:
documentation, or typed constants compiled into your services so a developer
cannot misspell an attribute name at all.

We already do the documentation half —
[`src/telemetry-docs/`](../src/telemetry-docs/) runs Weaver at build time and
serves the result at `/telemetry`. Mention codegen as the natural next step
without demoing it; it requires rebuilding services and does not earn its screen
time in a 20-minute slot.

### Two commands worth a passing mention

Both are strong answers to questions the audience will have.

- **`weaver registry infer`** — builds a first draft registry by inspecting OTLP
  messages you already produce. This is the answer to *"we have ten years of
  telemetry, we can't hand-write a schema for it"*. You do not start from a
  blank page; you start from what you already emit and curate down.
- **`weaver registry diff`** — compares two versions of the registry and reports
  what changed. This is how you catch a breaking change to a vocabulary other
  teams depend on, before you ship it.

---

## Good to know

- **`SpanAttributes` is `Map(LowCardinality(String), String)`.** Every
  attribute value is stored as a string regardless of its declared OpenTelemetry
  type, which is why the queries wrap `demo.order.amount` in `toFloat64OrZero`.
  Reading a missing key returns `''`, not an error, so the `!= ''` guard in
  Query 3 is what distinguishes "not recorded" from "recorded as zero", the
  exact distinction exercises 2 and 3 turn on.
- **Maturity of the ClickHouse exporter.** Traces and logs are beta, metrics
  are alpha. The argument of the demo rests on traces and logs; do not build a
  headline moment on the metrics tables.
- **Resources.** The full demo (about 28 services, two backends and a load
  generator) on a 3-node `kind` cluster wants about 6 CPUs and 10 GiB of memory
  for Docker. ClickHouse needs its 4 GiB limit: with 2 GiB it was killed under
  continuous ingestion of the three signals. On a smaller machine, set
  `LOCUST_BROWSER_TRAFFIC_ENABLED` to `"false"` in
  `chart/otel-demo/values.yaml`.
- **Telemetry is disposable.** The tables have a 24 hour TTL and ClickHouse has
  no persistent volume. `make demo-down` followed by `make demo-up` always
  returns to a clean start.

---

## Where this goes next

- **Loyalty tier origin.** Payment currently invents the customer's loyalty
  level itself. The architecturally correct fix is for it to originate upstream
  and travel in baggage, which the load generator already does for
  `session.id`. That is a much larger change than anything in the demo.
- **Code generation.** Weaver can generate typed constants from the registry so
  a service cannot misspell an attribute name at all. The documentation half is
  already in place, served at `/telemetry`.

---

## When something is slow or stuck

- The demo needs a few minutes after `make demo-up` before the load generator
  has produced enough data for the queries.
- On a machine that cannot keep up, set `LOCUST_BROWSER_TRAFFIC_ENABLED` to
  `"false"` in [`chart/otel-demo/values.yaml`](../chart/otel-demo/values.yaml)
  and run `helm upgrade otel-demo chart/otel-demo -n otel-demo`.
- If Grafana keeps restarting with `OOMKilled`, give it more memory: `kubectl -n
  otel-demo set resources deploy/grafana -c grafana --limits=memory=768Mi`.
- ClickHouse allows 16 queries at once. If you leave many dashboards open and
  run queries in a burst you may see `TOO_MANY_SIMULTANEOUS_QUERIES`. Try again.
- If `clickhouse.localhost` does not resolve on your system, add the line
  `127.0.0.1 clickhouse.localhost` to `/etc/hosts`.
- After a rollout of `telemetry-docs`, `/telemetry/` can answer 503 for a few
  seconds.
- `make demo-down` followed by `make demo-up` always gets you back to a clean
  start. If you applied or reverted the `checkout` patch, `git status` should
  show `src/checkout/main.go` clean once the fix is back.
