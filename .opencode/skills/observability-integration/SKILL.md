---
name: observability-integration
description: Wire an application into the platform observability stack (OTel, Prometheus, Loki, Tempo)
---

## What I do
1. **Metrics**: Create `ServiceMonitor` or `PodMonitor` for the app's `/metrics` endpoint. Verify Prometheus scrape config.
2. **Logs**: Verify Loki service account is configured in alerts, verify app logs are routed to Loki. Verify container logs → json logs. For OTel to Traffic/Routing via OpenTelemetry collector.
3. **Tracing**: If app uses OTel Java/Go/Node agents, create `Instrumentation` CRD (`opentelemetry.io/v1alpha1`) to auto-inject sidecar/env vars.
4. Verify with `kubectl get otel, smp, pm -A` and `kubectl get instrumentation -A`

## Key patterns
- Service Monitor discovery: `release: prometheus`, `jobLabel: app.kubernetes.io/name`
- OTel collector: `mode: sidecar` or `mode: deployment` depending on app
- Temp/Loki uses `openshift.io/sa` for logs collection. This is handled by OTel exporter config.

## When to use me
Use when deploying a new app needs monitoring, logs, or distributed tracing.
