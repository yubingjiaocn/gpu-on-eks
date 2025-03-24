################################################################################
# NVIDIA Device Plugin for Kubernetes
################################################################################

resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = "kube-system"
  version    = "0.17.1"  # Latest version

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

  # Configure the plugin to use the GFD (GPU Feature Discovery) feature
  set {
    name  = "gfd.enabled"
    value = "true"
  }

  # Enable MIG (Multi-Instance GPU) support if needed
  set {
    name  = "migStrategy"
    value = "none"  # Options: none, single, mixed
  }

  depends_on = [module.eks]
}