# Implementation Plan — Kubernetes-based Demo

This is the task breakdown for turning [DEMO.md](DEMO.md) into a working
demo and workshop, entirely on Kubernetes (`kind` locally, any cluster for
the recording). No docker-compose path exists any more — that scaffolding has
already been removed from this repo (see [§0](#0-what-is-already-done)).

Read this document to review and adjust the plan **before** implementation
starts. Nothing below has been built yet except where explicitly marked
verified.

---

## 0. What is already done

- All docker-compose files, `.env`/`.env.override`, and every Makefile target
  that shelled out to `docker compose` are deleted. The Makefile now only
  carries orchestrator-independent targets (lint, license headers, link
  checking, protobuf generation).
- `.github/workflows/run-telemetry-tests.yml` is deleted — it was entirely
  built around `docker compose up`/`logs` and could not run any more. It needs
  a full rewrite (§9) once the Kubernetes shape below is real, not a patch.
- `.github/workflows/checks.yml` needed no changes for this pivot: lint,
  license, link-check, and `weaver registry check` are all orchestrator
  independent.
- The upstream-only stack removed in the prior cleanup pass (agentic
  services, React Native app, eBPF profiling, chloggen/CHANGELOG tooling, 15
  upstream-only CI workflows) stays removed; none of it is reintroduced here.
- Per-service `src/*/Dockerfile`s are untouched and still needed — Kubernetes
  runs the same container images, it just orchestrates them differently.
- `src/otel-collector/otelcol-config*.yml` are kept as-is. They become the
  source of truth loaded into a ConfigMap (§4), not something rewritten from
  scratch — the redaction/OTTL/`span_metrics` logic in them already works and
  was already reviewed.

---

## 1. Decisions this plan makes by default

Flagged here, up front, so a disagreement surfaces once instead of once per
task below. Each includes the alternative considered and why it lost.

| # | Decision | Why | Alternative considered |
|---|---|---|---|
| D1 | **`kind`**, not minikube | Declarative multi-node config in one YAML file, no hypervisor/VM dependency (uses the Docker daemon directly), fast create/destroy — matters for a workshop attendees run repeatedly | minikube: heavier, VM-backed on most platforms, multi-node support is less first-class |
| D2 | **Helm**, vendoring the official `open-telemetry/opentelemetry-helm-charts` `opentelemetry-demo` chart as the base | That chart already exists, is versioned to match our `appVersion 3.0.0` pin, and already wires Jaeger/Prometheus/Grafana/OpenSearch/Collector as conditional subcharts — reusing it avoids hand-authoring ~30 manifests we would then have to keep in sync with upstream ourselves | Kustomize or raw manifests: full ownership, but rebuilds infrastructure upstream already maintains and diverges the fork further from rebasability |
| D3 | **Mixed image strategy**: pull `ghcr.io/open-telemetry/demo:3.0.0-<service>` for services we have not modified; build and `kind load docker-image` only for services we have | Building and loading ~28 images on a workshop attendee's laptop is a real time/flakiness cost; most services are untouched upstream code | Build everything locally: simpler mental model, much slower and heavier for no benefit on unmodified services |
| D4 | **Both observability backends run concurrently**, all the time — the Collector fans out to `otel-demo-swamp` and `otel-demo-mesh` simultaneously | Removes the compose plan's riskiest live-demo moment (a stop/restart transition) and is a genuinely stronger claim ("same live data, different lens") — see DEMO.md §3 | Toggle between backends via a values flag and a `helm upgrade`: mirrors the old compose "profile" model, but reintroduces the restart risk for no narrative gain |
| D5 | **Altinity Kubernetes Operator** (`ClickHouseInstallation` CRD) for the local/workshop ClickHouse, **Altinity Cloud** (external, via Secret) for the recording | Matches the Altinity theme of the talk, is a legitimate maintained operator, and models "how you'd actually run this" better than a bare StatefulSet | A plain `StatefulSet` + `Service`: fewer moving parts, but teaches nothing extra and the user already has an Altinity Cloud instance for the other target |
| D6 | **Namespaces**: `otel-demo` (app + Collector, always on), `otel-demo-swamp`, `otel-demo-mesh` | Backend swap without touching the app or its traffic; matches D4 | A single namespace: simpler `kubectl` commands, but blurs the "app vs. observability backend" boundary the talk is making |
| D7 | Keep `src/otel-collector/otelcol-config*.yml` as the ConfigMap source instead of starting from the official chart's default collector values | Preserves already-working custom logic (PII redaction, `gen_ai_normalizer`, `span_metrics` connector, `demo.` attribute sanitization) that the stock chart config does not have | Start from the chart's default values and re-add customizations: more "idiomatic" for the chart, but throws away tested work for no reason |

If any of D1–D7 should go the other way, say so before §2 onward starts —
several later tasks assume these.

---

## 2. Platform foundation

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 2.1 | `kind/cluster.yaml` — 1 control-plane + 2 worker node config, with `extraPortMappings` binding host `:8080` into the cluster | D1 | Node count is a placeholder (DEMO.md §8) — confirm against actual resource use once the chart exists |
| 2.2 | Ingress controller install step (ingress-nginx, or direct NodePort via `extraPortMappings` if simpler) | 2.1 | Whichever choice, verify it survives a full `kind delete cluster && kind create cluster` cycle — that is the exact workshop attendee flow |
| 2.3 | Single `Ingress` (or equivalent) routing all of `:8080` to the `frontend-proxy` Service in `otel-demo` | 2.2 | This is what keeps every existing `http://localhost:8080/...` link in DEMO.md valid unchanged |
| 2.4 | Namespace manifests: `otel-demo`, `otel-demo-swamp`, `otel-demo-mesh` | — | Trivial, but decide here whether they're Helm-managed (`--create-namespace` per release) or pre-created — affects task 3.1's structure |
| 2.5 | Resource budget check | 2.1 | Measure actual CPU/memory for the full cluster on a representative laptop before committing to the node count and service set in the recording |

---

## 3. Helm chart assembly

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 3.1 | Vendor or `helm dependency` the upstream `opentelemetry-demo` chart (v0.41.0 / appVersion 3.0.0) into `chart/` | D2 | Decide: git submodule, `helm dependency` in `Chart.yaml`, or a pinned vendored copy. Vendoring is easier to patch, `helm dependency` is easier to update — pick one and record why |
| 3.2 | `values-base.yaml` — our fork's identity: image overrides for services we've modified, our `telemetry-schema/`-baked `telemetry-docs` image, our `otel-config.yml` mount for `product-catalog` | 3.1 | Direct port of what `.env`/`compose.yaml` used to encode |
| 3.3 | Confirm `ghcr.io/open-telemetry/demo:3.0.0-<service>` tags exist for every service we have **not** modified | D3 | Do this **before** relying on it elsewhere in the plan — if tags are missing or mismatched, D3 needs revisiting |
| 3.4 | Disable the chart's own Jaeger/Prometheus/Grafana/OpenSearch subcharts if their defaults don't match what we need in `otel-demo-swamp`, or point their namespace at ours | 3.1, D6 | The stock chart likely deploys these into one namespace with the app; we want them split into `otel-demo-swamp` per D6 — confirm whether the chart's namespace handling supports this cleanly or needs a second small chart instead |
| 3.5 | `demo/queries/*.sql` — the query pack from DEMO.md Acts 2 and 5, numbered and commented | none | Orchestrator-independent; can happen any time |

---

## 4. Collector wiring

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 4.1 | ConfigMap(s) built from `src/otel-collector/otelcol-config.yml` + `-full.yml` + `-observability.yml`, delivered to the Collector Deployment | D7, 3.1 | Update the stale "Loaded when running with compose.X.yaml" header comments in those files while doing this — they're wrong the moment this lands |
| 4.2 | New `otelcol-config-mesh.yml` fragment: `clickhouse` exporter (already verified standalone, see DEMO.md §6 "Already verified"), plus a second OTLP exporter forking traffic to the Weaver live-check Service | 4.1 | This is the piece that makes D4 (concurrent backends) real |
| 4.3 | Collector env vars for `${env:...}` placeholders already in the config files, supplied via the Deployment spec / Helm values instead of an `.env` file | 4.1 | The collector's own native `${env:VAR}` expansion is unchanged by the orchestrator swap — only *how* the values reach the container changes |
| 4.4 | Secret for Altinity Cloud credentials (recording target) vs. Service pointing at the in-cluster `ClickHouseInstallation` (workshop target), selected by a values flag | D5, §5 | |
| 4.5 | Verify cross-namespace delivery end to end: Collector in `otel-demo` → Jaeger/Prometheus/OpenSearch in `otel-demo-swamp` **and** ClickHouse/Weaver in `otel-demo-mesh`, concurrently, under load-generator traffic | 4.1–4.4 | This is the single most important integration test in the whole plan — it's the mechanism the entire Act 2 narrative rests on |

---

## 5. ClickHouse on Kubernetes

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 5.1 | Install the Altinity Kubernetes Operator (`kubectl apply` its manifests, or a values-gated Helm step) into `otel-demo-mesh` | D5 | Confirm current recommended install method at implementation time — pin a version |
| 5.2 | `ClickHouseInstallation` (CHI) manifest sized for a laptop workshop | 5.1 | Start minimal (single replica, no sharding) — this is a demo, not a production deployment |
| 5.3 | One clean end-to-end run: operator up, CHI applied, Collector's `clickhouse` exporter reaches it, tables appear | 5.1, 5.2, 4.2 | Flagged as unverified in DEMO.md §4 — do this before trusting it for the workshop |
| 5.4 | Altinity Cloud path: Secret template + values flag to switch the Collector's `clickhouse` exporter endpoint | D5 | For the recording only; keep it optional so the workshop default never depends on it |

---

## 6. Weaver live-check deployment

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 6.1 | `Deployment` + `Service` running `otel/weaver:v0.25.1` (already the version this repo's `weaver-check` CI job resolves via the `telemetry-docs` Dockerfile pin — keep them in lockstep) with `registry live-check --input-source otlp` | 4.2 | Mount `telemetry-schema/` into the pod (ConfigMap or, more simply, bake it into a small image at build time — decide which) |
| 6.2 | `--emit-otlp-logs` wired back to the Collector, so findings land in ClickHouse as queryable telemetry | 6.1, 4.2 | This is the Act 4 "governance dashboard" beat |
| 6.3 | Throughput check under full load-generator traffic | 6.1 | Flagged as unverified in DEMO.md — sample the fork or point live-check at a subset of services if it can't keep up; `--no-stats` is available for long-running sessions |

---

## 7. Semantic layer / registry work

Orchestrator-independent — can proceed in parallel with everything above.

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 7.1 | Domain ownership annotations in `telemetry-schema/attributes/*.yaml` | none | Must keep `weaver registry check` green throughout |
| 7.2 | Rego policies under `telemetry-schema/policies/` (the `demo.` prefix rule, owning-domain requirement, etc. from DEMO.md §5) | none | |
| 7.3 | Wire `--policy` into the existing `weaver-check` job in `checks.yml` | 7.2 | One-line addition to an already-working job |
| 7.4 | The demo PR that adds `app.customer.tier` and gets rejected by CI (DEMO.md Act 4) | 7.2, 7.3 | This is a rehearsal artifact, not something merged |

---

## 8. Application-level fix

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 8.1 | Move the `span.SetAttributes` block in `src/checkout/main.go` to before `chargeCard` is called (DEMO.md Act 3) | none, can happen any time | The four-line fix the whole Act 3 narrative is built on |
| 8.2 | Rebuild the `checkout` image, `kind load docker-image` it into the cluster, roll the Deployment | 8.1, D3 | This is the one service D3 always builds locally, since it diverges from upstream the moment 8.1 lands |
| 8.3 | Re-run DEMO.md's Query 3 against the fix and confirm it returns a non-zero number | 8.2, 4.5 | The actual payoff moment — verify it before the recording, not during it |

---

## 9. CI rework

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 9.1 | Re-author `.github/workflows/run-telemetry-tests.yml` around `kind` + Helm (e.g. `helm/kind-action`) instead of `docker compose` | 2.1–2.4, 3.1 | The deleted workflow's pytest invocation and env thresholds (`WARMUP_SECONDS`, `POLL_TIMEOUT`, `WARMUP_PROBE_*`) are still valid reference values — recoverable from git history, not from scratch |
| 9.2 | Decide whether `test/telemetry/*.py` runs in-cluster (as a Job) or from the runner against port-forwarded/ingress URLs | 9.1 | Affects how the test container gets network access to the cluster |
| 9.3 | `test/telemetry/services.py` still has dead `agentic`-scope branches left over from the earlier stack removal — clean up once the test harness is being touched anyway for 9.1/9.2, not before | none | Low priority, bundle with 9.1 |

---

## 10. Workshop packaging

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 10.1 | `demo/README.md` — the five self-paced exercises with checkpoints from DEMO.md §7 | 3.1–8.3 (needs the real thing to exist first) | |
| 10.2 | `demo/queries/*.sql` | see 3.5 | |
| 10.3 | A single top-level `README`/`Makefile` entry point for "get the whole thing running" — even if it's a thin wrapper around `kind create cluster` + `helm install`, attendees need one documented starting command | 2.1, 3.1 | Resolves DEMO.md's open question about how much raw `kubectl`/`helm` the audience should see day-to-day vs. during the talk itself |

---

## 11. Documentation debt

Not required for the recording, but currently actively misleading and should
not ship long-term as-is:

| Task | Output | Notes |
|---|---|---|
| 11.1 | `README.md` and `CONTRIBUTING.md` still describe `docker compose`/`make start` extensively | Full content rewrite, deliberately deferred out of this plan's scope — flagging so it isn't forgotten |
| 11.2 | Every `src/*/README.md` that mentions `docker compose build <service>` as its build instructions | Same — lower priority, per-service |
| 11.3 | `.gitignore`'s stray `docker-compose.override.yml` entry | Harmless dead pattern, cheap to remove whenever someone is next in that file |

---

## 12. Rehearsal checklist

The final gate before the recording, once everything above lands:

- [ ] Full cold start: `kind create cluster` → `helm install` → app reachable
      at `:8080`, timed end to end
- [ ] Inject `paymentFailure`, confirm the swamp investigation in DEMO.md Act
      1 plays out as written
- [ ] Confirm Act 2's queries 1–3 return exactly what DEMO.md says, including
      Query 3's empty result
- [ ] Confirm Act 3's fix flips Query 3 to non-zero without redeploying
      anything else
- [ ] Confirm Act 4's Rego rejection and live-check misspelling detection both
      fire within a few seconds, not minutes
- [ ] Time the whole script; confirm it fits the actual talk slot, not just
      the ~20-minute estimate in DEMO.md
- [ ] One full `kind delete cluster` → cold start cycle on a clean machine,
      simulating an attendee, with no state left over from rehearsal

---

## Open decisions carried over from DEMO.md §8

These affect scope above and are still unresolved:

- How much `kubectl`/`helm` mechanics the audience sees on screen (affects
  task 10.3's design)
- Whether the `checkout` fix (task 8.1) gets contributed upstream as a real PR
- Whether payment's loyalty-tier origin gets fixed to travel in baggage
  (explicitly out of scope for the stage demo, noted as future work)
