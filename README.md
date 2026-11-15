<!-- markdownlint-disable-next-line -->
# <img src="https://opentelemetry.io/img/logos/opentelemetry-logo-nav.png" alt="OTel logo" width="45"> OpenTelemetry Demo

## Semantic observability demo (this fork)

This fork turns the OpenTelemetry Demo into a talk and a workshop, *Beyond the
Data Swamp: Building Your Semantic Observability Mesh*. It shows, on one running system, how to get from
"the payment service has errors" to "every failed checkout was a gold-tier
customer, worth this much":

- **One engine.** The Collector sends traces, metrics and logs to ClickHouse as
  well as to Jaeger, Prometheus and OpenSearch, and you query all of it with
  SQL.
- **A semantic layer.** [`telemetry-schema/`](./telemetry-schema/) is an
  OpenTelemetry Weaver registry: the vocabulary of the demo, grouped by business
  domain, with an owner for every attribute and a contract for every service.
- **A schema that stays true.** Weaver checks the registry in CI, enforces house
  rules written in Rego, and grades the live telemetry against it.

Everything runs on a local Kubernetes cluster, on your machine.

### Run it

You need Docker (about 6 CPUs and 10 GiB of memory available to it),
[`kind`](https://kind.sigs.k8s.io/), `kubectl`, `helm`, `make`, `curl`,
`openssl` and `python3`.

```bash
make demo-up      # about 10 to 20 minutes the first time
make demo-down    # delete the cluster
```

When it is up, everything is behind <http://localhost:8080>:

| URL | What |
|---|---|
| <http://localhost:8080> | The web shop |
| <http://localhost:8080/grafana/> | Grafana, with a ClickHouse data source |
| <http://localhost:8080/jaeger/ui/> | Jaeger |
| <http://localhost:8080/feature/> | Feature flags, where you inject the failure |
| <http://localhost:8080/loadgen/> | The load generator |
| <http://localhost:8080/telemetry/> | The telemetry schema, published by Weaver |
| <http://clickhouse.localhost:8080/play> | ClickHouse SQL client (user `demo`, password `demo`) |

`*.localhost` resolves to your machine, so there is nothing to configure. The
port is bound to `127.0.0.1`: nothing is exposed to your network.

### Where to go next

- [demo/README.md](./demo/README.md): the whole demo in one place. The idea
  behind it, the incident we use, five self-paced exercises with a checkpoint
  each, Weaver explained from zero, and what to do when something is slow or
  stuck.
- [`demo/queries/`](./demo/queries/): the SQL used in the demo.
  `demo/play-links.sh` prints a link to each one in the browser SQL client.

### What is in this repository

| Path | What |
|---|---|
| `telemetry-schema/` | The Weaver registry: attributes, metrics, services and Rego policies |
| `chart/otel-demo/` | Helm values on top of the official demo chart, including the Collector and its ClickHouse exporter |
| `chart/otel-demo-mesh/` | What this talk adds: ClickHouse, through the Altinity operator, and Weaver live-check |
| `kind/cluster.yaml` | The local cluster: one control plane and two workers |
| `demo/` | The exercises, the queries and the scripts for the policy check and the live-check |
| `src/` | The demo services. This fork changes `checkout`, `frontend-proxy`, `load-generator` and adds `telemetry-docs` and `weaver-live-check` |

The Docker Compose deployment of the upstream demo is not available in this
fork. The sections below are the upstream README and still describe the
upstream deployment options.

