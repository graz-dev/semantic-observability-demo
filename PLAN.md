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
| D3 | **Mixed image strategy**: pull `ghcr.io/open-telemetry/demo:3.0.0-<service>` for services we have not modified; build and `kind load docker-image` for `checkout` (once 8.1 lands), `telemetry-docs` (always, bakes in our `telemetry-schema/`), **`frontend-proxy`** (already diverged — `chatbot`/`profiles` routes and clusters removed in the scaffolding cleanup), and **`load-generator`** (already diverged — this fork runs Locust/Python, not upstream's k6/JavaScript; different source, different env vars, different exposed port entirely) | Building and loading ~28 images on a workshop attendee's laptop is a real time/flakiness cost; most services are untouched upstream code. Confirmed the chart's own image templating (`_objects.tpl`) already defaults every component to `ghcr.io/open-telemetry/demo:<appVersion>-<name>` — the untouched-service half of this strategy needs zero values overrides, it's the chart's stock behavior | Build everything locally: simpler mental model, much slower and heavier for no benefit on unmodified services |
| D4 | **Both observability backends run concurrently**, all the time — the Collector fans out to Jaeger/Prometheus/OpenSearch (in `otel-demo`) and `otel-demo-mesh` simultaneously | Removes the compose plan's riskiest live-demo moment (a stop/restart transition) and is a genuinely stronger claim ("same live data, different lens") — see DEMO.md §3 | Toggle between backends via a values flag and a `helm upgrade`: mirrors the old compose "profile" model, but reintroduces the restart risk for no narrative gain |
| D5 | **Altinity Kubernetes Operator** (`ClickHouseInstallation` CRD) for the local/workshop ClickHouse, **Altinity Cloud** (external, via Secret) for the recording | Matches the Altinity theme of the talk, is a legitimate maintained operator, and models "how you'd actually run this" better than a bare StatefulSet | A plain `StatefulSet` + `Service`: fewer moving parts, but teaches nothing extra and the user already has an Altinity Cloud instance for the other target |
| D6 | **Namespaces, revised after inspecting the real chart**: `otel-demo` (app + Collector + the chart's own Jaeger/Prometheus/Grafana/OpenSearch subcharts — i.e. "swamp" is just this chart deployed normally), `otel-demo-mesh` (our own additions: ClickHouse + Weaver live-check) | Verified against the actual chart templates: every subchart resolves its namespace to `.Release.Namespace`, so one release cannot natively split Jaeger/Prometheus/Grafana/OpenSearch into a separate namespace from the app without installing the whole chart three times with most components disabled in each — real cost for a boundary that's presentational, not technical. Two namespaces still draws the boundary that matters: "the official chart, deployed normally" vs. "what we built for the talk" | Original three-namespace draft (`otel-demo` / `otel-demo-swamp` / `otel-demo-mesh`): would need 2–3 installs of the same chart with disabled components each — not worth it once the chart's actual namespace handling was checked |
| D7 | **Revised after reading the chart's actual `opentelemetry-collector.config` value**: start from the chart's own default collector config and add only what's genuinely missing, rather than replacing it wholesale with `src/otel-collector/otelcol-config*.yml` | The chart's default `config:` is not a stub — it's a complete, K8s-native collector config, and it already carries most of what we assumed we'd have to port: `gen_ai_normalizer`, `span_metrics` connector, `filter/sanitize_profiles`, span-name sanitization, log sanitization. It *also* has real value ours never had (`hostMetrics`, `kubernetesAttributes`, `kubeletMetrics`, `clusterMetrics` presets — meaningful k8s-native enrichment a docker-compose config had no reason to include). Replacing it wholesale would silently throw that away. The one genuinely fork-specific piece actually missing is `transform/redact_sensitive_data` (PII redaction — card number truncation, CVV removal, email hashing) — that's what task 4.1 actually needs to port, not the whole file | Original D7: assumed the chart's collector config was minimal/replaceable; wrong once actually read |
| D8 | **No Ingress, no Gateway API** — a `NodePort` Service on `frontend-proxy`, reached via `kind`'s `extraPortMappings` | `frontend-proxy` (Envoy) already does 100% of the path-based L7 routing this demo needs (`/jaeger/ui`, `/grafana/`, `/feature/`, `/telemetry/`, `/loadgen/`, default → frontend) — a K8s-level router in front of it would duplicate that work for no benefit | Gateway API: the modern, correct answer *if* K8s-native L7 routing were actually needed here, which it isn't. `kubernetes/ingress-nginx`: ruled out on both counts — redundant layer, and retired by the Kubernetes project 2026-03-31 (unmaintained, no CVE patches) |

If any of D1–D8 should go the other way, say so before §2 onward starts —
several later tasks assume these.

---

## 2. Platform foundation

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 2.1 | `kind/cluster.yaml` — 1 control-plane + 2 worker node config, with `extraPortMappings` binding host `:8080` to container port `30080` | D1 | **Done, verified.** Cluster created, all 3 nodes `Ready`. Survived one full `kind delete cluster` + recreate cycle cleanly |
| 2.2 | ~~Ingress controller~~ — not needed, see D8 | — | Struck out; an earlier draft of this plan called for ingress-nginx before this was reconsidered and ruled out (retired by the Kubernetes project 2026-03-31, and would have been a redundant routing layer regardless) |
| 2.3 | `frontend-proxy` Service as `type: NodePort` with `nodePort: 30080` pinned, in `otel-demo` | 3.1, 3.4 | **Done, verified end to end.** Set via `components.frontend-proxy.service` in `chart/otel-demo/values.yaml` — no custom Service manifest needed, the chart exposes this directly. Confirmed `http://localhost:8080/`, `/jaeger/ui`, `/grafana/`, `/feature/`, `/telemetry/`, `/loadgen/` all resolve through the NodePort exactly as they did under compose |
| 2.4 | Namespace manifests: `otel-demo` (app + Collector + Jaeger/Prometheus/Grafana/OpenSearch, all from the one official-chart release), `otel-demo-mesh` (ClickHouse + Weaver live-check, ours) | — | `otel-demo` created and populated. `otel-demo-mesh` not yet created — comes with §5/§6 |
| 2.5 | Resource budget check | 2.1 | Idle 3-node cluster: ~1 GB RAM total. Under full real load, CPU eventually rose to the point of genuinely impairing verification (`kubectl exec` / `clickhouse-client` queries taking minutes) — investigated properly rather than just tolerated, see below. Memory was never the constraint at any point (worst case ~4.6 GiB of each node's 7.75 GiB limit) |

### Resource investigation and fixes — done properly, not just "reboot and hope"

Triggered by a `checkout` crash-loop after a Docker Desktop restart mid-session
surfacing just how loaded the machine had gotten. Diagnosed with real data
before touching anything:

- **Docker Desktop's CPU allocation is not artificially capped** — `docker
  info` reports `NCPU: 10`, matching the host exactly (`sysctl hw.ncpu`).
  There was no "give it more CPU" lever to pull; the host's 10 cores were
  already fully exposed to the cluster.
- **Memory does have real headroom** — Docker Desktop's VM is capped at
  ~7.75 GiB of the host's 16 GiB — but memory was never actually the
  constraint (see 2.5 above), so raising it would not have fixed the
  observed slowness. Not changed, for that reason.
- **`docker top` on the hottest node, broken down by process**, found the
  real cause: `clickhouse-server` alone at ~174% CPU (of its own 200%/2-CPU
  limit) — the single largest consumer — with a JVM process (OpenSearch, most
  likely) second. Root cause, confirmed by execing into the pod: `nproc`
  inside the ClickHouse container reports **10** (the host's core count —
  containers see the kernel's CPU count via `/proc`, not their own cgroup
  quota) against an actual cgroup limit of **2** (`cat /sys/fs/cgroup/cpu.max`
  → `200000 100000`). ClickHouse sizes per-query parallelism (`max_threads`)
  off the detected count by default, so ordinary queries were trying to run
  ~5x more concurrent work than 2 CPUs can serve — pure scheduling overhead.
- **Fix, with one wrong turn kept here as a warning:** first attempt capped
  both `profiles.default/max_threads: 2` *and* `settings.background_pool_size:
  4` — this crash-looped the server outright at startup with `Code: 36
  BAD_ARGUMENTS`, because ClickHouse's own sanity check requires
  `background_pool_size * background_merges_mutations_concurrency_ratio` to
  clear `number_of_free_entries_in_pool_to_execute_mutation` (default 20);
  `4 * 2 = 8` doesn't. Removed the `background_pool_size` override — it
  wasn't the setting that explained the observed symptom anyway — keeping
  only `max_threads: 2`. Confirmed stable across 7+ consecutive checks over
  90+ seconds afterward. `clickhouse-server`'s own CPU dropped 174% → 142%
  (~18%) — real, but modest.
- **The bigger lever turned out to be elsewhere.** `docker top` also showed
  headless Chrome processes (`LOCUST_BROWSER_TRAFFIC_ENABLED=true`, ~27%+18%
  CPU on one node) that a single ClickHouse setting was never going to
  touch. Turned it off for iterative dev work (`LOCUST_BROWSER_TRAFFIC_ENABLED:
  "false"` in `chart/otel-demo/values.yaml`) — **flip it back to `"true"`
  before the actual recording/rehearsal**, where full-fidelity browser
  traffic matters and this tradeoff is no longer worth making. Confirmed no
  Chrome processes remained anywhere in the cluster afterward, and aggregate
  CPU across all 3 nodes dropped from ~980% to ~830% of the host's 1000%
  (10-core) ceiling — the node that had been running ClickHouse specifically
  went from 583% to 400%.
- **A second, independent trim applied afterward:** disabled the collector's
  `hostMetrics`/`kubeletMetrics`/`clusterMetrics` presets in
  `chart/otel-demo/values.yaml`. Confirmed via the live rendered ConfigMap
  that the `hostmetrics`/`kubeletstats`/`k8s_cluster` receivers actually
  disappeared. Zero narrative cost — no Act in DEMO.md queries K8s
  infrastructure metrics, only app-level `demo.*` attributes and business
  signals — so this is pure savings. Left `kubernetesAttributes` alone (the
  `k8s_attributes` *processor*, cheap, and its `k8s.pod.name`/
  `k8s.namespace.name` enrichment is worth keeping for "this is really
  running on k8s" context) and `annotationDiscovery` (not confident enough
  about what else might depend on it to cut without checking).
- **Honest result after all four fixes (`max_threads`, browser traffic off,
  preset trim, plus everything settling for several minutes): still not
  good.** A trivial `SELECT count() FROM otel_traces` took **59.9 seconds**
  wall-clock. Telling detail: the local `kubectl exec` process itself only
  burned 0.23s of CPU — almost the entire minute was pure wait, not query
  execution. That points at **process-scheduling latency on a CPU-contended
  node**, not query cost — spawning a brand-new short-lived process (what
  every `kubectl exec` does) has to wait for a scheduling slot that
  continuously-running heavy processes are hogging, and no amount of
  ClickHouse-internal tuning fixes that.
- **Two things worth separating out before concluding the machine can't do
  this:** (1) a real, if partial, confound — this whole investigation
  involved dozens of ad-hoc `kubectl exec` verification queries in a short
  window, load the actual recording will not carry (a scripted run queries a
  handful of prepared statements, not continuous interactive debugging).
  (2) `kubectl exec` itself is one of the more expensive ways to reach a
  pod under contention — it always spawns a fresh process. **Not yet
  tried:** `kubectl port-forward` + a local `clickhouse-client`/`curl`,
  which reuses one connection instead of spawning a process per query, and
  should be measurably cheaper on a loaded node. Worth trying before
  concluding the fixes didn't help enough — task 6.2's remaining
  verification (do Weaver's findings really land in ClickHouse?) is the
  natural place to try it, once the machine has had a few idle minutes
  rather than immediately after another round of stress-testing.

---

## 3. Helm chart assembly

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 3.1 | Vendor or `helm dependency` the upstream `opentelemetry-demo` chart (v0.41.0 / appVersion 3.0.0) into `chart/` | D2 | **Done.** `chart/otel-demo/Chart.yaml` declares it as a Helm dependency (not vendored/submoduled) — we only supply values, never touch upstream's own templates, so `helm dependency update` re-pulling on a version bump is strictly simpler than a vendored copy would be to maintain |
| 3.2 | `chart/otel-demo/values.yaml` — our fork's identity: disable removed/unused components, `frontend-proxy` NodePort, image overrides for services we've modified, our `telemetry-schema/`-baked `telemetry-docs` image, our `otel-config.yml` mount for `product-catalog` | 3.1 | **In progress.** Done so far: `agent`/`mcp`/`chatbot`/`firepit`/`accounting`/`fraud-detection`/`kafka` disabled (removed stack + unused "full profile" extras); `checkout.initContainers: []` (its stock `wait-for-kafka` init container would otherwise hang forever once `kafka` is disabled — caught live, checkout sat in `Init:0/1` until this was added); `frontend-proxy` NodePort. Still open: image overrides for `frontend-proxy`/`checkout`/`telemetry-docs` once those are actually built locally (§8, §6); the `product-catalog` `otel-config.yml` question (3.6). **A third, more serious real bug found and fixed after a cluster restart**: `checkout` crash-looped (21 restarts) with a nil-pointer panic in `sendToPostProcessor` the moment it handled a real order. Root cause in `src/checkout/main.go`: the guard before calling it (`if cs.kafkaBrokerSvcAddr != ""`) only checks that `KAFKA_ADDR` is *set*, not that the Kafka producer actually connected — `kafka.CreateKafkaProducer()` failing (kafka disabled) only logs the error and leaves `KafkaProducerClient` nil, so the very next order placed panics. This is a genuine upstream bug independent of anything in this fork; docker-compose's "core" profile only avoided it by never setting `KAFKA_ADDR` at all. Fixed the same way here: `envOverrides: [{name: KAFKA_ADDR, value: ""}]`. Confirmed stable under continuous real order traffic afterward |
| 3.3 | Confirm `ghcr.io/open-telemetry/demo:3.0.0-<service>` tags exist for every service we have **not** modified | D3 | **Done, verified.** Checked directly against the registry for all 16 core services — see DEMO.md §6 |
| 3.4 | ~~Split Jaeger/Prometheus/Grafana/OpenSearch into their own namespace~~ — **done, resolved by D6's revision**: they stay in `otel-demo` with the app, as the chart deploys them by default | 3.1, D6 | Verified: every subchart template resolves its namespace to `.Release.Namespace` (e.g. `charts/grafana/templates/*.yaml` via `include "grafana.namespace"`), confirming no clean per-subchart namespace override exists — no further work needed here |
| 3.5 | `demo/queries/*.sql` — the query pack from DEMO.md Acts 2 and 5, numbered and commented | none | Orchestrator-independent; can happen any time |
| 3.6 | Confirm whether `product-catalog`'s `/otel-config.yml` is actually needed | none | **Closed, with real evidence.** Once ClickHouse was queryable, ran the deferred re-check: `SELECT ... FROM otel_traces WHERE ServiceName = 'product-catalog'` shows `demo.product.id` and `demo.product.name` present on real spans. The service instruments itself correctly without the file mount — the speculative ConfigMap-mount plumbing was correctly never built |

### First bootstrap install — what actually happened

`helm install otel-demo chart/otel-demo -n otel-demo --create-namespace` was
run against 3.1+3.2 as they stood. Two real (self-contained, now-understood)
issues surfaced, beyond the expected first-pull wait for ~20 images:

- `shipping` crash-looped a handful of times with `Failed to initialize flagd
  provider: transport error` — it panics if `flagd` isn't reachable yet
  rather than retrying indefinitely. Self-healed once `flagd` finished
  starting; not a bug, just a cold-start ordering artifact worth knowing
  about, not worth fixing.
- `checkout` really did hang in `Init:0/1` indefinitely — its stock
  `wait-for-kafka` init container has no way to succeed once `kafka` is
  disabled. Fixed by the `checkout.initContainers: []` override in 3.2.

All 25 pods in `otel-demo` reached `Running`/Ready. `http://localhost:8080/`,
`/jaeger/ui`, `/grafana/`, `/feature/`, `/telemetry/`, and `/loadgen/` were
each curled directly and returned healthy responses (200, or 307/308
redirects to the canonical trailing-slash path) — full parity with the
docker-compose `:8080` experience, confirmed, not assumed. At this point
`frontend-proxy` was still running upstream's stock image.

### Proving the local-build mechanism on `frontend-proxy`

With D3 confirmed workable in principle, `frontend-proxy` (already known to
have diverged — see D3) was built locally and loaded to prove the mechanism
end to end, not just described:

```
docker build -f src/frontend-proxy/Dockerfile -t otel-demo-fork/frontend-proxy:local .
kind load docker-image otel-demo-fork/frontend-proxy:local --name otel-demo
```

Plus `components.frontend-proxy.imageOverride` (`repository`/`tag`/
`pullPolicy: Never`) in `chart/otel-demo/values.yaml`. First rollout crashed
immediately: `SocketAddressValidationError: Address: value length must be at
least 1 characters` — Envoy's bootstrap validation failing on an empty
`envsubst` substitution. Root cause, and the reason it's listed as its own
D3 exception now: **`load-generator` is a fourth diverged component** — this
fork runs Locust (Python) in place of upstream's k6 (JavaScript), a real
source-level difference, not just a template edit. Our `envoy.tmpl.yaml`
expects `${LOCUST_WEB_HOST}`/`${LOCUST_WEB_PORT}` for the `/loadgen/` route;
the chart's stock env list for `frontend-proxy` was written for its own
k6-oriented template and has never heard of either variable.

Fixed with `envOverrides` (upsert, not replace, so the chart's other needed
vars for this component stay intact):

```yaml
components:
  frontend-proxy:
    envOverrides:
      - name: LOCUST_WEB_HOST
        value: load-generator
      - name: LOCUST_WEB_PORT
        value: "8089"
```

After that, `frontend-proxy` came up clean. Re-verified every route,
including a control test: `/chatbot/` and `/profiles/` now return the exact
same 308 self-redirect as a deliberately made-up path — confirming they fall
through to the generic `frontend` catch-all rather than hitting a leftover
cluster, i.e. the removal in the earlier scaffolding cleanup really is fully
in effect. `/loadgen/` now correctly 503s (no Service backs it yet, since
`load-generator` itself is still upstream's k6 image) rather than crashing —
building `load-generator` locally the same way is the natural next task.

### `load-generator` — the fourth diverged component, built and verified

Same mechanism, applied for real:

```
docker build -f src/load-generator/Dockerfile -t otel-demo-fork/load-generator:local .
kind load docker-image otel-demo-fork/load-generator:local --name otel-demo
```

Values needed three things the stock chart has no equivalent for at all,
since it's built around k6, not Locust: a full `envOverrides` list (`LOCUST_*`
+ `FLAGD_OFREP_PORT`, ported 1:1 from docker-compose's old `.env`), a
`service.port: 8089` (the stock chart never exposes a load-gen web UI
Service), and `resources.limits.memory: 1500Mi` (compose sized it there
specifically because `LOCUST_BROWSER_TRAFFIC_ENABLED=true` drives real
headless-Chromium traffic, not just HTTP — the chart's stock 512Mi is sized
for k6's lighter footprint).

Verified past "the pod is Running": `curl http://localhost:8080/loadgen/stats/requests`
returned `"state": "running"` with real request stats, including a live
`/api/checkout` failure — Locust is actually driving traffic against the real
webstore, not just serving its own UI page.

**D3 is now fully resolved for all four diverged components**
(`frontend-proxy`, `load-generator`; `checkout` and `telemetry-docs` still
pending their own triggers — §8.2 and §6.1 respectively).

---

## 4. Collector wiring

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 4.1 | *(revised per D7)* Add `transform/redact_sensitive_data` to `opentelemetry-demo.opentelemetry-collector.config` in `chart/otel-demo/values.yaml` | D7, 3.1 | **Done, verified.** Read the *live rendered* ConfigMap (not the raw values) before and after to confirm the merge behaved exactly as intended: the processor appears, and it's wired into the traces pipeline alongside the chart's own `k8s_attributes`/`memory_limiter`/etc — none of which we had to restate, since only pipelines actually being changed need their lists rewritten |
| 4.2 | Add a `clickhouse` exporter, appended into the `traces`/`metrics`/`logs` pipelines' exporter lists | 4.1 | **Done, verified end to end, not just "config applied."** Collector pods rolled with 0 errors. ClickHouse auto-created its schema on first connection (same 9 tables as the earlier standalone verification). Real counts after a few minutes of live-generator traffic: 10,376 trace rows, 3,360 log rows, 22,545 metric rows across `otel_metrics_sum`/`otel_metrics_gauge`. This is the piece that makes D4 (concurrent backends) real — Jaeger/Prometheus/OpenSearch and ClickHouse are simultaneously receiving the same live traffic, confirmed by row counts on one side and the routes already verified working on the other |
| 4.3 | Add a second OTLP exporter forking traffic to the Weaver live-check Service | 4.2, §6 | **Done, verified with a real bug fixed along the way.** `otlp/weaver` exporter added to the traces pipeline. First rollout dropped every batch: `rpc error: code = Unimplemented desc = Content is compressed with gzip which isn't supported` — the collector's OTLP exporter gzips by default, weaver's OTLP receiver doesn't decompress it. Fixed with `compression: none` on that exporter. After the fix: 0 export errors, and weaver's own live-check output is visibly processing real, continuous span traffic from the actual demo (confirmed by reading its violation report against genuine `image-provider`/`frontend-proxy` spans, not just synthetic test data) |
| 4.4 | Secret for Altinity Cloud credentials (recording target) vs. Service pointing at the in-cluster `ClickHouseInstallation` (workshop target), selected by a values flag | D5, §5 | |
| 4.5 | Verify delivery end to end: Collector in `otel-demo` → Jaeger/Prometheus/OpenSearch in the same namespace **and**, cross-namespace, ClickHouse/Weaver in `otel-demo-mesh`, concurrently, under load-generator traffic | 4.1–4.4 | This is the single most important integration test in the whole plan — it's the mechanism the entire Act 2 narrative rests on. Load-generator is already live and driving real traffic (confirmed `"state": "running"` via its stats API), so this task has real signal to verify against from the moment it starts |

---

## 5. ClickHouse on Kubernetes

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 5.1 | Install the Altinity Kubernetes Operator into the cluster | D5 | **Done.** Official install bundle (`kubectl apply -f .../clickhouse-operator-install-bundle.yaml`, operator v0.27.3, confirmed against the live repo rather than assumed). Installs cluster-wide into `kube-system` and watches all namespaces — the operator itself isn't namespace-scoped to `otel-demo-mesh`, only the CHI resource it manages is |
| 5.2 | `ClickHouseInstallation` (CHI) manifest sized for a laptop workshop | 5.1 | **Done, resized once from real evidence.** `chart/otel-demo-mesh/` — a standalone chart (no upstream dependency, unlike `chart/otel-demo/`), templating a single-shard/single-replica CHI, based on Altinity's own published examples, not guessed syntax. First sizing guess (2Gi memory limit) **OOMKilled live** under real continuous three-signal ingestion from load-generator traffic — confirmed via `Last State: OOMKilled` on the pod, not inferred. Bumped to 2Gi request / 4Gi limit, stable since under the same load. Take the 2Gi number as a real *floor* to exceed for the workshop's minimum spec, not a starting guess |
| 5.3 | One clean end-to-end run: operator up, CHI applied, reachable, queryable | 5.1, 5.2 | **Done, verified — twice.** `SELECT version()` via `kubectl exec` into the ClickHouse pod directly succeeded (`25.3.14.14`). Then, separately, a throwaway pod launched *in `otel-demo`* queried ClickHouse *in `otel-demo-mesh`* over its cluster DNS name and got a clean result — this is task 4.5's cross-namespace reachability concern, resolved before writing a line of collector config, not after. The operator creates a stable per-CHI Service named `clickhouse-<chi-name>` (`clickhouse-clickhouse` here) exposing `8123` (HTTP) and `9000` (native) — this naming pattern wasn't documented anywhere findable, so it was confirmed empirically rather than assumed |
| 5.4 | Altinity Cloud path: Secret template + values flag to switch the Collector's `clickhouse` exporter endpoint | D5 | **Blocked on the user** — needs real Altinity Cloud endpoint/credentials, which only they have. Not started |

---

## 6. Weaver live-check deployment

| Task | Output | Depends on | Notes |
|---|---|---|---|
| 6.1 | `Deployment` + `Service` running `otel/weaver:v0.25.1` with `registry live-check --input-source otlp` | 4.2 | **Done, verified.** Went with "bake it into a small image at build time" (the option this task's note left open) — `src/weaver-live-check/Dockerfile` mirrors `src/telemetry-docs/Dockerfile`'s exact pattern (`COPY telemetry-schema /telemetry-schema`), so it's a fifth D3-style local build, no ConfigMap/volume plumbing needed. `chart/otel-demo-mesh/templates/weaver-live-check.yaml` — 100% our own template, no upstream dependency, matching this chart's nature. **Real bug found and fixed:** the default `--inactivity-timeout` is 10s — without real traffic yet (4.3 wasn't wired at first boot), the pod crash-looped every 10s. Fixed with an explicit `--inactivity-timeout 604800` so it behaves like every other long-running Deployment regardless of traffic gaps |
| 6.2 | `--emit-otlp-logs` wired back to the Collector, so findings land in ClickHouse as queryable telemetry | 6.1, 4.2 | **Partially verified — one more real bug found and fixed, one link still unconfirmed.** First attempt failed outright: `TonicLogsClient export failed: invalid URI` — weaver's OTLP logs exporter rejects a bare `host:port`, needs an explicit scheme (`http://...`). Fixed, and the error is gone. **Not yet independently confirmed:** that findings are actually landing as rows in `otel_logs`. Sent a deliberate `demo.user_context.loyaltyLevel` (camelCase) violation directly at weaver and confirmed *weaver itself* flagged it correctly, but could not confirm the row on the ClickHouse side — the machine was under heavy load during this check (~580% CPU on one node) and `clickhouse-client` queries were taking minutes each, making this specific link impractical to nail down in that session. Re-check once the machine has headroom, ideally with `kubectl port-forward` + a local client instead of `kubectl exec` to cut latency |
| 6.3 | Throughput check under full load-generator traffic | 6.1 | Incidentally exercised, not formally measured: weaver has been continuously processing real traffic (app spans, not just the synthetic test) without crashing or falling behind visibly. A real number (findings/sec sustained, memory growth over time) is still worth capturing before the recording |

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
