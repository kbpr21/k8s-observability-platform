prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: true

additionalServiceMonitors:
  - name: gateway-monitor
    additionalLabels:
      release: prometheus-stack
    selector:
      matchLabels:
        app: gateway
    namespaceSelector:
      matchNames:
        - ${app_namespace}
    endpoints:
      - port: web
        path: /metrics
        interval: 10s
        relabelings:
          - targetLabel: service
            replacement: gateway
  - name: orders-monitor
    additionalLabels:
      release: prometheus-stack
    selector:
      matchLabels:
        app: orders
    namespaceSelector:
      matchNames:
        - ${app_namespace}
    endpoints:
      - port: web
        path: /metrics
        interval: 10s
        relabelings:
          - targetLabel: service
            replacement: orders
  - name: payments-monitor
    additionalLabels:
      release: prometheus-stack
    selector:
      matchLabels:
        app: payments
    namespaceSelector:
      matchNames:
        - ${app_namespace}
    endpoints:
      - port: web
        path: /metrics
        interval: 10s
        relabelings:
          - targetLabel: service
            replacement: payments

additionalPrometheusRulesMap:
  app-alerts:
    groups:
      - name: app-alerts
        rules:
          - alert: PaymentsHighErrorRate
            expr: rate(http_requests_total{status=~"5..", service="payments"}[1m]) / rate(http_requests_total{service="payments"}[1m]) > 0.05
            for: 30s
            labels:
              severity: critical
            annotations:
              summary: "Payments service high error rate"
              description: "Payments service has failed more than 5% of requests over the last 30s."
          - alert: GatewayHighLatency
            expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service="gateway"}[1m])) by (le)) > 1.0
            for: 30s
            labels:
              severity: warning
            annotations:
              summary: "Gateway high latency"
              description: "Gateway p95 request latency exceeds 1.0s."
          - alert: PodCrashLooping
            expr: kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1
            for: 30s
            labels:
              severity: critical
            annotations:
              summary: "Container crash looping"
              description: "A container in pod {{ $labels.pod }} is crash looping."

alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'service']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 1h
      receiver: 'null'
      routes:
        - match:
            severity: critical
          receiver: 'critical-webhook'
        - match:
            severity: warning
          receiver: 'warning-webhook'
    inhibit_rules:
      - source_match:
          alertname: 'PaymentsHighErrorRate'
        target_match:
          alertname: 'GatewayHighLatency'
        equal: []
    receivers:
      - name: 'null'
      - name: 'critical-webhook'
        webhook_configs:
          - url: 'http://localhost:5001/critical'
      - name: 'warning-webhook'
        webhook_configs:
          - url: 'http://localhost:5001/warning'

grafana:
  additionalDataSources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.monitoring.svc.cluster.local:3100
      version: 1
      editable: true
