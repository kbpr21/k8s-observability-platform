variable "install_observability" {
  type        = bool
  default     = true
  description = "Deploy the observability stack (kube-prometheus-stack, Loki, Promtail, NGINX Ingress). Set to false to skip in environments where the stack is not required."
}

variable "image_tag" {
  description = "Immutable Docker image tag (short git SHA) shared by all three microservices."
  type        = string
}

variable "gateway_replicas" {
  type        = number
  default     = 2
  description = "Number of replicas for the gateway deployment."
}

variable "orders_replicas" {
  type        = number
  default     = 2
  description = "Number of replicas for the orders deployment."
}

variable "payments_replicas" {
  type        = number
  default     = 1
  description = "Number of replicas for the payments deployment. Pinned to 1 so the in-memory fault toggle affects every request."
}
