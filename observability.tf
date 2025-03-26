################################################################################
# Observability Components
# - kube-prometheus-stack for Prometheus, Grafana, and Alertmanager
# - DCGM Exporter for GPU metrics
################################################################################

# Create namespace for monitoring
resource "kubernetes_namespace" "monitoring" {
  count = var.enable_observability ? 1 : 0

  metadata {
    name = "monitoring"
  }

  depends_on = [module.eks]
}

# Create IAM role for Prometheus using EKS Pod Identity
resource "aws_iam_role" "prometheus_role" {
  count = var.enable_observability ? 1 : 0

  name = "${var.cluster_name}-prometheus-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = local.tags
}

# Create EKS Pod Identity Association for Prometheus
resource "aws_eks_pod_identity_association" "prometheus" {
  count = var.enable_observability ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace.monitoring[0].metadata[0].name
  service_account = "prometheus-kube-prometheus-stack-prometheus"
  role_arn        = aws_iam_role.prometheus_role[0].arn
}

# Generate random password for Grafana admin
resource "random_password" "grafana_password" {
  count   = var.enable_observability ? 1 : 0
  length  = 16
  special = false

  # Prevent password from changing on subsequent terraform applies
  lifecycle {
    ignore_changes = all
  }
}

# Deploy kube-prometheus-stack using Helm
resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_observability ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "70.1.1"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name

  # Configure Prometheus, Grafana, and add NVIDIA DCGM dashboard
  values = [
    <<-EOT
    prometheus:
      prometheusSpec:
        serviceMonitorSelectorNilUsesHelmValues: false
        serviceMonitorSelector: {}
        podMonitorSelector: {}
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: ebs-sc
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 50Gi
            selector: {}

    grafana:
      adminUser: admin
      adminPassword: ${random_password.grafana_password[0].result}
      defaultDashboardsEnabled: true

      persistence:
        enabled: true
        size: 10Gi
        storageClassName: ebs-sc

      dashboardProviders:
        dashboardproviders.yaml:
          apiVersion: 1
          providers:
          - name: 'default'
            orgId: 1
            folder: ''
            type: file
            disableDeletion: false
            editable: true
            options:
              path: /var/lib/grafana/dashboards/default

      dashboards:
        default:
          nvidia-dcgm:
            gnetId: 12239
            revision: 2
            datasource: Prometheus

    alertmanager:
      enabled: false
    EOT
  ]

  depends_on = [
    kubernetes_namespace.monitoring,
    aws_eks_pod_identity_association.prometheus,
    kubernetes_storage_class.ebs_storage_class
  ]
}

# Deploy DCGM Exporter for GPU metrics
resource "helm_release" "dcgm_exporter" {
  count = var.enable_observability ? 1 : 0

  name       = "dcgm-exporter"
  repository = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart      = "dcgm-exporter"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  version    = "4.0.4"

  set {
    name  = "serviceMonitor.enabled"
    value = "true"
  }

  set {
    name  = "serviceMonitor.additionalLabels.release"
    value = "kube-prometheus-stack"
  }

  set {
    name  = "service.type"
    value = "ClusterIP"
  }

  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  set {
    name  = "nodeSelector.karpenter\\.sh/nodepool"
    value = "gpu"
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# Output the Grafana credentials and URL
output "grafana_admin_username" {
  description = "Grafana admin username"
  value       = var.enable_observability ? "admin" : null
  sensitive   = false
}

output "grafana_admin_password" {
  description = "Grafana admin password"
  value       = var.enable_observability ? random_password.grafana_password[0].result : null
  sensitive = true
}

output "grafana_url" {
  description = "URL to access Grafana (via kubectl port-forward)"
  value       = var.enable_observability ? "Run: kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 80:80" : null
}

output "prometheus_url" {
  description = "URL to access Prometheus (via kubectl port-forward)"
  value       = var.enable_observability ? "Run: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090" : null
}