# OpenTelemetry Demo Telemetry Schema

This directory contains the semantic conventions and telemetry schema for the
OpenTelemetry Demo application, defining all custom attributes and metrics used
across the demo services.

## Structure

The schema is organized into three directories:

- **`attributes/`** - Attribute definitions organized by business domain
  (ad, cart, exchange, feature flag, order, payment, product, recommendation,
  request, shipping, user)
- **`services/`** - Service-specific attribute references (one file per service)
- **`metrics/`** - Metric definitions (one file per service that produces
  metrics)

## Purpose

This schema provides a single source of truth for all custom telemetry in the
OpenTelemetry Demo application, ensuring naming consistency and enabling
validation of instrumentation code.

## Domains and policies

Every attribute in `attributes/<domain>.yaml` names its owning domain in
`annotations.owner`, and a domain can declare that one of its attributes only
makes sense together with another domain's through `annotations.depends_on`
(for example `demo.order.amount` depends on `demo.user_context.loyalty_level`).

The Rego policies in `policies/` enforce these house rules in the `Weaver check`
CI job, through `weaver registry check -p`. Each finding is reported under one
of these ids:

| Id | Rejects |
|---|---|
| `app_prefix_reserved` | An attribute starting with `app.`, which is reserved for client side instrumentation |
| `missing_demo_prefix` | An attribute defined here without the `demo.` prefix. Reuse the upstream semantic convention attribute instead |
| `missing_owner` | An attribute without `annotations.owner` |
| `owner_domain_mismatch` | An owner that differs from the domain file the attribute is defined in |
| `unknown_dependency` | A `depends_on` entry that no domain defines |
| `same_domain_dependency` | A `depends_on` entry owned by the same domain |

To run the check locally, mount this directory into the Weaver image pinned in
`src/telemetry-docs/Dockerfile` and run
`registry check -r source -p source/policies`.
