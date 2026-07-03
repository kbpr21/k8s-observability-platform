global:
  scrape_interval: 15s
  evaluation_interval: 15s

# Disable components not needed for automated alerting assertions.
grafana:
  enabled: false

kubeStateMetrics:
  enabled: false

nodeExporter:
  enabled: false

prometheusOperator:
  admissionWebhooks:
    enabled: false
  tls:
    enabled: false

prometheus:
  prometheusSpec:
    # Only pick up ServiceMonitors that carry the release label.
    serviceMonitorSelectorNilUsesHelmValues: true
    # Silence default Kubernetes rule groups; keep only app-level rules.
    ruleSelector:
      matchLabels:
        app: kube-prometheus-stack
        release: prometheus-stack
    ruleNamespaceSelector: {}
    resources:
      requests:
        cpu: 100m
        memory: 300Mi
      limits:
        cpu: 500m
        memory: 512Mi
    retention: 1h
    storageSpec: {}

alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 20m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 1h
      receiver: 'null'
    inhibit_rules:
      - source_matchers:
          - alertname="PaymentsHighErrorRate"
        target_matchers:
          - alertname="GatewayHighLatency"
        equal: []
    receivers:
      - name: 'null'

additionalPrometheusRulesMap:
  app-alerts:
    groups:
      - name: app-alerts
        rules:
          - alert: PaymentsHighErrorRate
            expr: >
              rate(http_requests_total{status=~"5..", service="payments"}[1m])
              /
              rate(http_requests_total{service="payments"}[1m])
              > 0.05
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Payments service high error rate"
              description: "Payments /charge has a >5% error rate over the last minute."
          - alert: GatewayHighLatency
            expr: >
              histogram_quantile(
                0.95,
                sum(rate(http_request_duration_seconds_bucket{service="gateway"}[1m])) by (le)
              ) > 1.0
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "Gateway p95 latency above 1 s"
              description: "Gateway p95 request latency exceeds 1.0 s."
