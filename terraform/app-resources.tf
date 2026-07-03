# TLS Certificates Generation for devops-project.local
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem
  is_ca_certificate = true

  subject {
    common_name  = "DevOps Project Root CA"
    organization = "DevOps Org"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "key_encipherment",
    "digital_signature"
  ]
}

resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem

  subject {
    common_name  = "devops-project.local"
    organization = "DevOps Org"
  }

  dns_names = ["devops-project.local"]
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem   = tls_cert_request.server.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth"
  ]
}

resource "kubernetes_secret" "gateway_tls" {
  metadata {
    name      = "gateway-tls"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_locally_signed_cert.server.cert_pem
    "tls.key" = tls_private_key.server.private_key_pem
  }
}

# --- Redis Cache ---
resource "kubernetes_deployment_v1" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = "redis"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        container {
          name  = "redis"
          image = "redis:7-alpine"
          port {
            container_port = 6379
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = {
      app = "redis"
    }
    port {
      port        = 6379
      target_port = 6379
    }
    type = "ClusterIP"
  }
}

# --- Payments Service ---
resource "kubernetes_deployment_v1" "payments" {
  metadata {
    name      = "payments"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = "payments"
    }
  }

  spec {
    replicas = var.payments_replicas # Pinned to 1 for consistent fault injection
    selector {
      match_labels = {
        app = "payments"
      }
    }

    template {
      metadata {
        labels = {
          app = "payments"
        }
      }

      spec {
        container {
          name  = "payments"
          image = "payments:${var.image_tag}"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "web"
            container_port = 8000
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "payments" {
  metadata {
    name      = "payments"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = "payments"
    }
  }

  spec {
    selector = {
      app = "payments"
    }
    port {
      name        = "web"
      port        = 8000
      target_port = 8000
    }
    type = "ClusterIP"
  }
}

# --- Orders Service ---
resource "kubernetes_deployment_v1" "orders" {
  metadata {
    name      = "orders"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = "orders"
    }
  }

  spec {
    replicas = var.orders_replicas
    selector {
      match_labels = {
        app = "orders"
      }
    }

    template {
      metadata {
        labels = {
          app = "orders"
        }
      }

      spec {
        container {
          name  = "orders"
          image = "orders:${var.image_tag}"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "web"
            container_port = 8000
          }
          env {
            name  = "APP_REDIS_HOST"
            value = "redis.app.svc.cluster.local"
          }
          env {
            name  = "APP_REDIS_PORT"
            value = "6379"
          }
          env {
            name  = "PAYMENTS_SERVICE_URL"
            value = "http://payments.app.svc.cluster.local:8000/charge"
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "orders" {
  metadata {
    name      = "orders"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = "orders"
    }
  }

  spec {
    selector = {
      app = "orders"
    }
    port {
      name        = "web"
      port        = 8000
      target_port = 8000
    }
    type = "ClusterIP"
  }
}

# --- Gateway Service ---
resource "kubernetes_deployment_v1" "gateway" {
  metadata {
    name      = "gateway"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = "gateway"
    }
  }

  spec {
    replicas = var.gateway_replicas
    selector {
      match_labels = {
        app = "gateway"
      }
    }

    template {
      metadata {
        labels = {
          app = "gateway"
        }
      }

      spec {
        container {
          name  = "gateway"
          image = "gateway:${var.image_tag}"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "web"
            container_port = 8000
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "gateway" {
  metadata {
    name      = "gateway"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app = "gateway"
    }
  }

  spec {
    selector = {
      app = "gateway"
    }
    port {
      name        = "web"
      port        = 8000
      target_port = 8000
    }
    type = "ClusterIP"
  }
}

# --- Network Policies ---

# Payments Network Policy: only accept ingress from orders, redis, and monitoring namespaces (Prometheus)
resource "kubernetes_network_policy_v1" "payments_netpol" {
  metadata {
    name      = "payments-netpol"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "payments"
      }
    }

    # Allow from Orders service pods
    ingress {
      from {
        pod_selector {
          match_labels = {
            app = "orders"
          }
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }

    # Allow from Monitoring namespace (Prometheus scraping)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}

# Orders Network Policy: only accept ingress from gateway and monitoring namespace
resource "kubernetes_network_policy_v1" "orders_netpol" {
  metadata {
    name      = "orders-netpol"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "orders"
      }
    }

    # Allow from Gateway
    ingress {
      from {
        pod_selector {
          match_labels = {
            app = "gateway"
          }
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }

    # Allow from Monitoring namespace (Prometheus scraping)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}

# Gateway Network Policy: only accept ingress from NGINX ingress controller namespace and monitoring namespace
resource "kubernetes_network_policy_v1" "gateway_netpol" {
  metadata {
    name      = "gateway-netpol"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "gateway"
      }
    }

    # Allow from Ingress controller namespace
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ingress"
          }
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }

    # Allow from Monitoring namespace (Prometheus scraping)
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}

# --- NGINX Ingress Resource ---
resource "kubernetes_ingress_v1" "gateway_ingress" {
  count = var.install_observability ? 1 : 0

  metadata {
    name      = "gateway-ingress"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"               = "nginx"
      "nginx.ingress.kubernetes.io/limit-rps"     = "10"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "15"
    }
  }

  spec {
    tls {
      hosts       = ["devops-project.local"]
      secret_name = kubernetes_secret.gateway_tls.metadata[0].name
    }

    rule {
      host = "devops-project.local"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.gateway.metadata[0].name
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
  }
}

# --- HPAs ---
resource "kubernetes_horizontal_pod_autoscaler_v2" "gateway_hpa" {
  metadata {
    name      = "gateway-hpa"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    min_replicas = 2
    max_replicas = 5

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.gateway.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type               = "Utilization"
          average_utilization = 80
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "orders_hpa" {
  metadata {
    name      = "orders-hpa"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    min_replicas = 2
    max_replicas = 5

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.orders.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type               = "Utilization"
          average_utilization = 80
        }
      }
    }
  }
}

# --- Service Monitors ---
resource "kubernetes_manifest" "gateway_monitor" {
  count = var.install_observability ? 1 : 0

  depends_on = [helm_release.prometheus_stack]

  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "gateway-monitor"
      namespace = "monitoring"
      labels = {
        release = "prometheus-stack"
      }
    }
    spec = {
      namespaceSelector = {
        matchNames = [kubernetes_namespace.app.metadata[0].name]
      }
      selector = {
        matchLabels = {
          app = "gateway"
        }
      }
      endpoints = [
        {
          port     = "web"
          path     = "/metrics"
          interval = "10s"
          relabelings = [
            {
              targetLabel = "service"
              replacement = "gateway"
            }
          ]
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "orders_monitor" {
  count = var.install_observability ? 1 : 0

  depends_on = [helm_release.prometheus_stack]

  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "orders-monitor"
      namespace = "monitoring"
      labels = {
        release = "prometheus-stack"
      }
    }
    spec = {
      namespaceSelector = {
        matchNames = [kubernetes_namespace.app.metadata[0].name]
      }
      selector = {
        matchLabels = {
          app = "orders"
        }
      }
      endpoints = [
        {
          port     = "web"
          path     = "/metrics"
          interval = "10s"
          relabelings = [
            {
              targetLabel = "service"
              replacement = "orders"
            }
          ]
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "payments_monitor" {
  count = var.install_observability ? 1 : 0

  depends_on = [helm_release.prometheus_stack]

  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "payments-monitor"
      namespace = "monitoring"
      labels = {
        release = "prometheus-stack"
      }
    }
    spec = {
      namespaceSelector = {
        matchNames = [kubernetes_namespace.app.metadata[0].name]
      }
      selector = {
        matchLabels = {
          app = "payments"
        }
      }
      endpoints = [
        {
          port     = "web"
          path     = "/metrics"
          interval = "10s"
          relabelings = [
            {
              targetLabel = "service"
              replacement = "payments"
            }
          ]
        }
      ]
    }
  }
}



