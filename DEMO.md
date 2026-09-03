# Beyond the Data Swamp — Demo Plan

Companion demo for the talk *"Beyond the Data Swamp: Building Your Semantic
Observability Mesh"* (see [TALK.md](TALK.md)).

This document is two things at once:

- the **script** for the demo we record and present, and
- the **workshop** that attendees can clone and run on their own machine
  afterwards.

Everything here runs on this fork of the OpenTelemetry Demo. No slides are
required to follow it.

---

## 1. The story, for someone who has never heard of observability

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

Telemetry is almost always written in **technical** vocabulary: `service=payment`,
`status=ERROR`, `p99=2.3s`. So when something breaks, you can see *what* broke.
You cannot answer the questions that anyone actually asks in an incident review:

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
   present sometimes and missing others, and nobody trusts it enough to build on.

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

## 2. The incident we use, and why it is perfect

We drive the whole demo with one fault, injected at runtime through flagd with
no rebuild: **`paymentFailure`**.

Two properties of this codebase make it an unusually good vehicle. Both are
already in the upstream demo; we did not plant them.

### It fails along a business dimension, not a technical one

In [`src/payment/charge.js:42-48`](src/payment/charge.js#L42-L48), the injected
failure is stamped with `demo.user_context.loyalty_level = gold`:

```js
if (numberVariant > 0) {
  // n% chance to fail with demo.user_context.loyalty_level=gold
  if (Math.random() < numberVariant) {
    span.setAttributes({'demo.user_context.loyalty_level': 'gold' });
    throw new Error('Payment request failed. Invalid token. ...');
  }
}
```

On a technical dashboard this looks like uniform random noise at 5%. Sliced by
one business attribute, it is *"you are losing your best customers, and only
your best customers"*. Same bytes, completely different conclusion. That is the
thesis of the talk, already sitting in the demo.

### The number you need is only recorded on the happy path

In [`src/checkout/main.go`](src/checkout/main.go), `chargeCard` is called at
line 356, and the order attributes — including `demo.order.amount` — are only
set at line 390, **after** the charge succeeds. When payment fails, checkout
returns early and the order value is never recorded at all.

This is the single most valuable beat in the demo, because it is a completely
real and extremely common bug:

> The data you need to size the business impact is only written on the happy
> path. It goes missing exactly when you need it.

It also gives the three acts genuine causal necessity rather than a decorative
progression:

- **Act 1 (silos):** you cannot even ask the question.
- **Act 2 (ClickHouse):** you can ask it, and you get *half* an answer. You
  discover the failures are all gold-tier. But "how much money" comes back
  empty — proving that a fast engine alone is not enough.
- **Act 3 (semantic layer + Weaver):** you define the contract, the attribute
  moves to where the contract says it must be, and live-check proves every
  service now honours it. The query finally returns the number.

---

## 3. Demo architecture: one cluster, three namespaces

Everything runs on Kubernetes — a local `kind` cluster for rehearsal and the
workshop, the same manifests against any cluster for the recording. There is
no docker-compose path any more; see [PLAN.md](PLAN.md) for the full
implementation plan and rationale behind every choice below.

### Cluster shape

```
kind cluster (1 control-plane + 2 workers)
├── namespace: otel-demo            the webstore app, load generator, flagd,
│                                    and the OTel Collector — always on
├── namespace: otel-demo-swamp      Jaeger, Prometheus, Grafana, OpenSearch
└── namespace: otel-demo-mesh       ClickHouse, Weaver live-check
```

Multiple nodes are not cosmetic: they let the audience see pods actually
scheduled and load-balanced across machines, which a single-node cluster
would paper over.

### The important change from a compose-based plan: both backends run at once

The compose version of this plan had Act 2 tear down the swamp stack and
bring up a separate mesh stack (`make stop && make start-mesh`). On
Kubernetes there is no reason to do that: cross-namespace DNS just works, so
**the same Collector fans out to both `otel-demo-swamp` and `otel-demo-mesh`
concurrently, all the time.**

```
services ──▶ OTel Collector ──┬──▶ Jaeger / Prometheus / OpenSearch   (otel-demo-swamp)
              (otel-demo)     └──▶ ClickHouse                          (otel-demo-mesh)
                               └──▶ Weaver live-check ──▶ findings as OTLP logs ──▶ ClickHouse
```

This is strictly better for a live recording: Act 2 stops being a
stop-the-world transition with dead air while containers restart, and becomes
"same live data, now look at it through a different lens." Nothing goes down
between acts. The narrative in [section 4](#4-the-demo-script) is written
for this version.

### Ingress: the URLs do not change

`frontend-proxy` (Envoy) already does all the path-based routing this demo
needs — `/jaeger/ui`, `/grafana/`, `/feature/`, `/telemetry/`, `/loadgen/` all
resolve through one process on one port today. On Kubernetes, one Ingress (or
`kind`'s `extraPortMappings`, TBD in PLAN.md) points at the `frontend-proxy`
Service in `otel-demo`, and every `http://localhost:8080/...` link already
used throughout this document keeps working unchanged. This is why the
narrative content below barely moves — only *how the cluster comes up*
changes, not what you click once it's up.

### ClickHouse target

Two supported targets, matching the original plan's intent but expressed as
Kubernetes objects instead of environment variables:

| Target | Used for | How |
|---|---|---|
| **Altinity Cloud** | the recorded talk demo | a Secret holding the endpoint/credentials, referenced by the Collector's `clickhouse` exporter config |
| **Altinity Kubernetes Operator, local `ClickHouseInstallation`** | the workshop, and offline rehearsal | the default in `otel-demo-mesh`; no external account needed |

> **Decision to confirm:** the workshop must default to the local,
> operator-managed ClickHouse — attendees will not have an Altinity Cloud
> account, and a workshop that only works with our credentials is not a
> workshop. The recording uses Altinity Cloud to make the "this scales and it
> is cheap" claim concrete on real infrastructure.

---

## 4. The demo script

Total running time ≈ 18–20 minutes when recorded. Each act is independently
recordable, so a bad take does not cost the whole session.

### Act 0 — The system (1–2 min)

```bash
kind create cluster --config kind/cluster.yaml
helm install otel-demo ./chart -n otel-demo --create-namespace
```

(Exact commands settle during implementation — see PLAN.md. The shape stays:
one `kind` cluster, one Helm release, done.)

Show the webstore at <http://localhost:8080>. Twenty-odd services in a dozen
languages, with a load generator producing continuous realistic traffic,
spread across a multi-node cluster — `kubectl get pods -n otel-demo -o wide`
is worth one glance here to make "this is not a toy" concrete: real pods,
real nodes, real scheduling.

### Act 1 — The swamp (4 min)

Inject the fault at <http://localhost:8080/feature/> — set `paymentFailure` to
`25%`. Wait ~2 minutes for signal.

Now investigate it the way a normal team does, and narrate the friction:

1. **Grafana** → the error rate on `payment` climbs. You know *something* is wrong.
2. **Jaeger** → filter for failed traces on `payment`. You can open one trace and
   read `demo.user_context.loyalty_level = gold` on the span. **One** trace.
3. **OpenSearch** → find the matching log line by pasting the trace ID.

Then ask the business question out loud:

> Across all failures in the last fifteen minutes — which customer tiers were
> hit, and what is the total order value at risk?

And show that you cannot answer it. Jaeger has no `GROUP BY`; it is a trace
viewer, not an analytics engine. Prometheus never saw `loyalty_level` because
putting a high-cardinality business attribute into metric labels is exactly what
you are told never to do. OpenSearch has some of it, in a third query language,
without the trace context.

**Land the point:** the problem is not missing data. Every byte you need was
collected. The problem is that there is no surface on which the question can be
asked, and no shared vocabulary in which to ask it.

### Act 2 — One engine (5 min)

No restart, no `make stop`. The same Collector that fed Jaeger/Prometheus/
OpenSearch in Act 1 has been exporting to ClickHouse the whole time — you are
about to look at the exact same live data through a different lens. Say that
explicitly; it is a stronger claim live than a stack switch would have been.

Show the three-line addition to the collector config that made it happen
(the `clickhouse` exporter block, see PLAN.md for where it lives as a
ConfigMap), then show the tables the exporter created by itself
on first connection (`create_schema: true`):

```
otel_traces                          otel_metrics_gauge
otel_traces_trace_id_ts              otel_metrics_sum
otel_traces_trace_id_ts_mv           otel_metrics_histogram
otel_logs                            otel_metrics_exponential_histogram
                                     otel_metrics_summary
```

Worth saying out loud: nobody designed this schema, and there is no ETL job.
The exporter created it, and every one of those is an ordinary MergeTree table —
so all three signals are joinable with plain SQL from the first minute.

**Query 1 — the technical view, the one Grafana already gave you:**

```sql
SELECT
    ServiceName,
    countIf(StatusCode = 'STATUS_CODE_ERROR') AS errors,
    count() AS total,
    round(100 * errors / total, 2) AS error_pct
FROM otel_traces
WHERE Timestamp > now() - INTERVAL 15 MINUTE
GROUP BY ServiceName
ORDER BY error_pct DESC
LIMIT 10;
```

Same answer as the dashboard — but now it is SQL, so it composes.

**Query 2 — the reveal:**

```sql
SELECT
    SpanAttributes['demo.user_context.loyalty_level'] AS loyalty_tier,
    countIf(StatusCode = 'STATUS_CODE_ERROR') AS failed,
    count() AS total
FROM otel_traces
WHERE ServiceName = 'payment'
  AND Timestamp > now() - INTERVAL 15 MINUTE
GROUP BY loyalty_tier
ORDER BY failed DESC;
```

Every single failure sits in `gold`. This is the moment the audience should feel
the difference: one `GROUP BY` on a business attribute turned "5% errors" into
"we are only failing our best customers".

**Query 3 — the question that still cannot be answered:**

```sql
WITH failed AS (
    SELECT DISTINCT TraceId
    FROM otel_traces
    WHERE ServiceName = 'payment'
      AND StatusCode = 'STATUS_CODE_ERROR'
      AND Timestamp > now() - INTERVAL 15 MINUTE
)
SELECT
    count() AS lost_orders,
    round(sum(toFloat64OrZero(SpanAttributes['demo.order.amount'])), 2) AS revenue_at_risk
FROM otel_traces
WHERE TraceId IN (SELECT TraceId FROM failed)
  AND SpanAttributes['demo.order.amount'] != ''
  AND Timestamp > now() - INTERVAL 15 MINUTE;
```

**It returns zero.** Not because ClickHouse failed — because
`demo.order.amount` is written after the charge succeeds, so failed checkouts
never record it.

Do not fix this yet. Sit in it. The honest conclusion:

> A fast, cheap, unified engine bought us the ability to *ask*. It did not buy
> us the ability to *answer*. That takes meaning, and meaning has to be designed.

**Cost note to land here:** columnar storage plus compression makes the
high-cardinality business attributes — user IDs, order IDs, loyalty tiers — the
kind of thing you can now afford to keep, precisely the data that a metrics
system forces you to throw away.

### Act 3 — The semantic layer (5 min)

Start from the tribal-knowledge problem in Act 2: those queries only worked
because the presenter happened to know the attribute is spelled
`demo.user_context.loyalty_level` and lives on the `payment` span. Nobody else
in the company knows that. It is not written down anywhere a person or a tool
can find.

Except in this repo it *is*. Show [`telemetry-schema/`](telemetry-schema/):

```
telemetry-schema/
├── manifest.yaml          # the registry: version, semconv dependency
├── attributes/            # vocabulary, grouped by business domain
│   ├── user.yaml          #   demo.user_context.loyalty_level lives here
│   ├── order.yaml
│   └── payment.yaml
├── metrics/               # metric definitions, per service
└── services/              # what each service declares it emits
```

Open [`attributes/user.yaml`](telemetry-schema/attributes/user.yaml) and read
one definition aloud — key, type, brief, stability, examples. That is a
vocabulary entry: a business concept given a single official spelling, a type,
and a meaning.

Then show [`services/payment.yaml`](telemetry-schema/services/payment.yaml):
the payment service *declares* which attributes it emits. That is a contract,
not documentation.

And show it published: <http://localhost:8080/telemetry> — the whole vocabulary
as a browsable site, generated from the YAML by Weaver, so a new engineer can
discover it without asking anyone.

**Then make it a mesh.** Today the registry is one flat pile. Give each domain
an explicit owner and explicit dependencies, so that:

- the **user** domain owns `demo.user_context.loyalty_level` and is accountable
  for it,
- the **order** domain *depends on* it, because order-value analysis is
  meaningless without customer tier,
- payment must not invent its own user attribute — today it literally does, by
  randomising a loyalty level inside the payment service. That is a domain
  boundary violation, and it is visible in the code at
  [`charge.js:65`](src/payment/charge.js#L65).

**Then fix Act 2's empty result, driven by the contract.** The order domain
declares that `demo.order.amount` is `required` on every checkout attempt —
success or failure. Move the `span.SetAttributes` block in
[`src/checkout/main.go`](src/checkout/main.go) to just after `total` is
computed and before `chargeCard` is called. Rebuild one service, re-run Query 3,
and the number appears.

The point to make: the code change is four lines. The reason anyone knew to make
it is the contract.

### Act 4 — Weaver, and how the schema stays true (4 min)

See [section 5](#5-weaver-explained-from-zero) below for the explanation to
deliver here. The demo beats are:

1. **`weaver registry check`** — already wired into CI at
   [`checks.yml:113`](.github/workflows/checks.yml#L113). Show it passing.
2. **A Rego policy** — add a house rule ("every demo attribute must use the
   `demo.` prefix, never `app.`; every attribute must name an owning domain").
   Open a PR that adds `app.customer.tier`, and show CI reject it. This is how a
   vocabulary stays *one* vocabulary as an organisation grows.
3. **`weaver registry live-check`** — the strongest beat. Fork a copy of the
   live OTLP stream into Weaver and have it grade the real telemetry against the
   registry, in real time. Introduce a service emitting
   `demo.user_context.loyaltyLevel` (camelCase typo) and watch it get flagged
   within seconds — something no amount of code review would have caught.
4. **Close the loop.** Run live-check with `--emit-otlp-logs` pointed back at
   the collector, so schema violations land in ClickHouse as telemetry:

   ```sql
   SELECT ServiceName, Body, count()
   FROM otel_logs
   WHERE ScopeName LIKE '%live_check%'
   GROUP BY ServiceName, Body
   ORDER BY count() DESC;
   ```

   Governance becomes a queryable dashboard: *which teams are drifting from the
   standard, and by how much*.

### Act 5 — The payoff (1 min)

Re-run the full investigation on the finished system. One query, no tribal
knowledge, a business answer:

```sql
SELECT
    t.SpanAttributes['demo.user_context.loyalty_level'] AS tier,
    count() AS failed_orders,
    round(sum(toFloat64OrZero(t.SpanAttributes['demo.order.amount'])), 2) AS revenue_at_risk
FROM otel_traces AS t
WHERE t.ServiceName = 'checkout'
  AND t.StatusCode = 'STATUS_CODE_ERROR'
  AND t.Timestamp > now() - INTERVAL 15 MINUTE
GROUP BY tier
ORDER BY revenue_at_risk DESC;
```

Closing line: the swamp was never a storage problem. It was a **meaning**
problem, and meaning is something you design, publish, and enforce — exactly
like an API.

---

## 5. Weaver, explained from zero

This is the material for Act 4, written so it can be delivered to someone who
has never heard of OpenTelemetry.

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
[`telemetry-schema/`](telemetry-schema/). One entry looks like this:

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
  [AGENTS.md](AGENTS.md)),
- every attribute must declare an owning domain,
- no attribute may duplicate a concept upstream semconv already defines,
- an attribute marked `stable` may never change type.

Analogy: **the linter with your team's style guide**. `check` is the language;
Rego is your organisation's rules on top of it.

The demo moment is a PR adding `app.customer.tier` being rejected by CI with a
readable explanation. That is governance that scales without a review bottleneck.

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
telemetry, which is how you get the governance dashboard in Act 4).

#### `weaver registry generate` — publish it

Renders the registry through templates into whatever artefact you need:
documentation, or typed constants compiled into your services so a developer
cannot misspell an attribute name at all.

We already do the documentation half — [`src/telemetry-docs/`](src/telemetry-docs/)
runs Weaver at build time and serves the result at `/telemetry`. Mention codegen
as the natural next step without demoing it; it requires rebuilding services and
does not earn its screen time in a 20-minute slot.

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

## 6. What we have to build

Moved to [PLAN.md](PLAN.md) — that document owns the full task breakdown
(Kubernetes platform, Helm chart, ClickHouse, Weaver live-check, the
`telemetry-schema` mesh work, CI, and workshop packaging), phased and ordered
by dependency, for review before implementation starts.

### Already verified

Tested end to end against the exact versions this repo pins, so these are facts
rather than assumptions:

- **All three signals reach ClickHouse and are queryable together.** The
  `clickhouseexporter` in contrib `0.159.0` reports `traces: Beta`,
  `logs: Beta`, `metrics: Alpha`. With `create_schema: true` it builds the nine
  tables listed in Act 2 on startup, unprompted.
- **A single SQL statement can join across all three signals** — traces to logs
  on `TraceId`, and to metrics on `ServiceName` — because they are ordinary
  MergeTree tables in one database. No federation layer, no ETL.
- **`SpanAttributes` is `Map(LowCardinality(String), String)`.** Every attribute
  value is stored as a string regardless of its declared OTel type, which is why
  the queries above wrap `demo.order.amount` in `toFloat64OrZero`. Reading a
  missing key returns `''`, not an error, so the `!= ''` guard in Query 3 is what
  distinguishes "not recorded" from "recorded as zero" — the exact distinction
  Act 2 turns on.
- **The Act 2 semantic query pattern works as written**, including
  `GROUP BY SpanAttributes['demo.user_context.loyalty_level']` with a summed
  order amount.

### Things to verify before committing to them

These are assumptions in the plan that have not been tested yet, listed so they
get checked rather than discovered on stage:

- **Trace/log correlation on real demo traffic.** Joining logs to traces needs
  `TraceId` populated on log records. The demo services do emit logs with trace
  context — today's Grafana config already correlates Jaeger to OpenSearch via
  `filterByTraceID` — but confirm the coverage in ClickHouse before scripting a
  log-based beat around it.
- **Metrics exporter maturity.** Metrics are `Alpha` while traces and logs are
  `Beta`. The demo's argument rests on traces, so this is not load-bearing, but
  do not build a headline moment on the metrics tables.

- **Checkout error status.** Act 2 Query 3 and Act 5 assume the `checkout` span
  is marked `STATUS_CODE_ERROR` when the charge fails. The deferred
  `span.RecordError` in `main.go` suggests it is, but confirm in real data.
- **Altinity Cloud from the collector.** TLS, native vs HTTP port, and
  credentials handling through a Kubernetes Secret need one end-to-end test
  well before the recording.
- **live-check throughput.** The full demo generates a lot of spans. Test
  whether live-check keeps up, and if not, sample the fork or point it at a
  subset of services. `--no-stats` exists for long-running sessions.
- **Machine load.** The full ~28-service demo plus two backend namespaces on a
  3-node `kind` cluster is a real resource ask on a laptop. Measure it, and
  have a smaller-footprint fallback ready (fewer nodes, swamp-only or
  mesh-only namespace) if the recording machine cannot hold it.

### K8s-specific, not yet verified at all

These are new questions introduced by the Kubernetes pivot, distinct from the
ClickHouse-level facts above, which remain true regardless of orchestrator:

- **Cross-namespace DNS fan-out under real load.** The "both backends run
  concurrently" design in [section 3](#3-demo-architecture-one-cluster-three-namespaces)
  assumes the Collector in `otel-demo` can reach Services in `otel-demo-swamp`
  and `otel-demo-mesh` without extra networking config. This is standard
  Kubernetes behavior but has not been tried against this specific chart setup.
- **Altinity Kubernetes Operator on `kind`.** Needs one clean end-to-end run:
  install the operator, apply a `ClickHouseInstallation`, confirm the
  Collector can reach it, before trusting it for the workshop.
- **Image availability.** The mixed image strategy in PLAN.md assumes
  `ghcr.io/open-telemetry/demo:3.0.0-<service>` tags exist for every
  unmodified service. Confirm before relying on it.
- **Ingress vs `extraPortMappings`.** Whichever mechanism preserves
  `http://localhost:8080` needs to survive a full cluster teardown/recreate
  cycle, since that is exactly what a workshop attendee will do.

---

## 7. Workshop packaging

The repo is the takeaway. Attendees need `kind`, `kubectl`, `helm`, and Docker
— nothing else — and get:

```bash
kind create cluster --config kind/cluster.yaml
helm install otel-demo ./chart -n otel-demo --create-namespace
kind delete cluster
```

(Provisional; PLAN.md is the source of truth for exact commands once the
chart and cluster config exist. Both backend namespaces come up with the
single Helm release — there is no separate "swamp" vs "mesh" install step,
per [section 3](#3-demo-architecture-one-cluster-three-namespaces).)

`demo/README.md` walks through the same five acts as self-paced exercises, each
with a checkpoint the attendee can verify:

1. Inject `paymentFailure` and try to answer the business question in Jaeger.
   *Checkpoint: you cannot, and you can say precisely why.*
2. Run queries 1 and 2 against ClickHouse. *Checkpoint: all failures are gold.*
3. Run query 3 and get zero. *Checkpoint: you can explain the empty result.*
4. Read the contract, fix `checkout`, rebuild the image, `kind load
   docker-image`, roll the deployment, re-run query 3.
   *Checkpoint: the number appears.*
5. Add an attribute that violates a Rego policy; watch `weaver registry check`
   fail. Emit a misspelled attribute; watch `live-check` flag it.
   *Checkpoint: both fail for the reason you expected.*

Keeping the fork close to upstream matters here — the demo stays valuable only
if it can be rebased as the OpenTelemetry Demo evolves. That is why the plan
vendors the official `opentelemetry-helm-charts` chart as a base and adds new
files on top (a values overlay, a small chart for ClickHouse/Weaver
live-check, `demo/`) rather than hand-writing manifests from scratch, with the
single deliberate exception of the four-line `checkout` change, which is the
point of Act 3.

---

## 8. Open questions

- **Recording length.** The script is ~20 minutes. If the talk slot gives the
  demo less, Act 1 is the one to compress — it can become a 60-second
  screenshot montage without losing the argument.
- **Does the checkout fix belong in a PR upstream?** Recording order value only
  on the happy path is arguably a genuine bug in the upstream demo. Contributing
  the fix would be a nice closing note, but it would also remove the beat from
  future runs of this workshop against upstream.
- **Loyalty tier origin.** Payment currently invents the customer's loyalty
  level itself. The architecturally correct fix is for it to originate upstream
  and travel in baggage, which the load generator already does for `session.id`.
  That is a much larger change — worth raising as "here is where this goes next"
  rather than doing on stage.
- **How much `kubectl`/`helm` should the audience actually see?** Act 0
  currently shows one `kubectl get pods -o wide` to earn "this is real infra"
  credibility, then gets out of the way. An alternative is hiding cluster
  mechanics behind a single wrapper command entirely and never showing
  Kubernetes on screen at all, since the talk is about telemetry semantics,
  not container orchestration. Current draft keeps one glance and no more;
  revisit once the chart exists and startup time is known.
- **Node count.** Three nodes (1 control-plane + 2 workers) is a guess tuned
  for "visibly distributed without melting a laptop." PLAN.md should confirm
  actual resource use before the recording, not assume this number is right.
