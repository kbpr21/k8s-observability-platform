variable "install_observability" {
  type        = bool
  default     = true
  description = "Toggle to install the observability stack (kube-prometheus-stack, loki, promtail, nginx-ingress). Set to false in CI to reduce resources."
}

variable "gateway_replicas" {
  type        = number
  default     = 2
  description = "Number of replicas for gateway service"
}

variable "orders_replicas" {
  type        = number
  default     = 2
  description = "Number of replicas for orders service"
}

variable "payments_replicas" {
  type        = number
  default     = 1
  description = "Number of replicas for payments service (pinned to 1 for consistent fault injection)"
}
