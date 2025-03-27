################################################################################
# Neuron Device Plugin for Kubernetes
################################################################################

resource "helm_release" "neuron_device_plugin" {
  count = var.enable_neuron ? 1 : 0

  name       = "neuron"
  repository = "oci://public.ecr.aws/neuron"
  chart      = "neuron-helm-chart"
  namespace  = "kube-system"
  version    = "1.1.1"  # Latest version
  create_namespace = true

  set {
    name  = "npd.enabled"
    value = "false"
  }

  set {
    name  = "scheduler.enabled"
    value = "true"
  }

  depends_on = [module.eks]
}

resource "kubectl_manifest" "karpenter_neuron_nodeclass" {
  count = var.enable_neuron ? 1 : 0
  yaml_body = <<-YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: neuron
spec:
  amiSelectorTerms:
  - alias: al2023@latest
  role: ${module.karpenter.node_iam_role_name}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${local.name}
  tags:
    karpenter.sh/discovery: ${local.name}
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 200Gi
        volumeType: gp3
        iops: 6000
        throughput: 1000
        deleteOnTermination: true
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_neuron_nodepool" {
  count = var.enable_neuron ? 1 : 0
  yaml_body = <<-YAML
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: neuron
spec:
  template:
    metadata:
      labels:
        launch-type: karpenter
        node-class: neuron
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: neuron
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["inf2"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["8xlarge"]
      taints:
        - key: aws.amazon.com/neuron
          effect: NoSchedule
  limits:
    "aws.amazon.com/neuroncore": 100
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 1m
  YAML

  depends_on = [kubectl_manifest.karpenter_neuron_nodeclass]
}
