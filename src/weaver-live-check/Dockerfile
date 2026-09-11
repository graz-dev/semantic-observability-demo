# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Bakes telemetry-schema/ into the same Weaver image src/telemetry-docs
# already uses, so `weaver registry live-check` has a local registry to grade
# incoming telemetry against — no ConfigMap/volume plumbing needed. Same
# version pin as telemetry-docs and the weaver-check CI job; keep them in
# lockstep (see PLAN.md §6).
FROM docker.io/otel/weaver:v0.25.1@sha256:9ad46ca9cd4fa5974b121f886aa3e9946a8ef8ea905001a96c018d21f9db87ca

COPY telemetry-schema /telemetry-schema

ENTRYPOINT ["/weaver/weaver"]
