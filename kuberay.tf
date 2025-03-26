################################################################################
# KubeRay Operators
################################################################################

resource "helm_release" "kuberay-operator" {
  count = var.enable_kuberay_operator ? 1 : 0

  name       = "kuberay"
  repository = "https://ray-project.github.io/kuberay-helm/"
  chart      = "kuberay-operator"
  namespace  = "default"
  version    = "1.3.1"  # Latest version
  create_namespace = true

  depends_on = [module.eks]
}