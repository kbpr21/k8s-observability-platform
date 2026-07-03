# Namespaces
resource "kubernetes_namespace" "app" {
  metadata {
    name = "app"
  }
}

resource "kubernetes_namespace" "monitoring" {
  count = var.install_observability ? 1 : 0
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_namespace" "ingress" {
  count = var.install_observability ? 1 : 0
  metadata {
    name = "ingress"
  }
}

# Helm Ingress NGINX (only installed when observability is true)
resource "helm_release" "nginx_ingress" {
  count      = var.install_observability ? 1 : 0
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress[0].metadata[0].name

  values = [
    <<-EOF
    controller:
      updateStrategy:
        type: RollingUpdate
      service:
        type: NodePort
      hostPort:
        enabled: true
      nodeSelector:
        ingress-ready: "true"
      tolerations:
        - key: "node-role.kubernetes.io/control-plane"
          operator: "Equal"
          effect: "NoSchedule"
        - key: "node-role.kubernetes.io/master"
          operator: "Equal"
          effect: "NoSchedule"
      publishService:
        enabled: false
      extraArgs:
        publish-status-address: "localhost"
    EOF
  ]

  depends_on = [kubernetes_namespace.ingress]
}

# Helm kube-prometheus-stack
resource "helm_release" "prometheus_stack" {
  count      = var.install_observability ? 1 : 0
  name       = "prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  wait       = true

  values = [
    templatefile("${path.module}/templates/prometheus-values.yaml.tpl", {
      app_namespace = kubernetes_namespace.app.metadata[0].name
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# Helm Loki
resource "helm_release" "loki" {
  count      = var.install_observability ? 1 : 0
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  wait       = false

  values = [
    file("${path.module}/loki-values.yaml")
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# Helm Promtail
resource "helm_release" "promtail" {
  count      = var.install_observability ? 1 : 0
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name

  values = [
    file("${path.module}/promtail-values.yaml")
  ]

  depends_on = [helm_release.loki]
}
