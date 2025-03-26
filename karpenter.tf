
################################################################################
# Karpenter with EKS Pod Identity
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.34"

  cluster_name = module.eks.cluster_name
  create_pod_identity_association = true
  enable_v1_permissions = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    AmazonS3FullAccess = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  }

  tags = local.tags
}

resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.3.3"  # Latest version

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }

  set {
    name = "serviceAccount.name"
    value = "karpenter"
  }

  depends_on = [module.eks]
}

################################################################################
# Security Group for Karpenter Nodes
################################################################################

resource "aws_security_group" "karpenter_nodes" {
  name        = "${local.name}-karpenter-nodes-sg"
  description = "Security group for nodes provisioned by Karpenter"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
    Name                     = "${local.name}-karpenter-nodes-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow all outbound traffic
resource "aws_security_group_rule" "karpenter_nodes_egress" {
  security_group_id = aws_security_group.karpenter_nodes.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound traffic"
}

# Allow inter-node communication within the Karpenter security group
resource "aws_security_group_rule" "karpenter_nodes_self_ingress" {
  security_group_id        = aws_security_group.karpenter_nodes.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.karpenter_nodes.id
  description              = "Allow inter-node communication within Karpenter security group"
}

# Allow communication from EKS control plane to Karpenter nodes
resource "aws_security_group_rule" "karpenter_nodes_cluster_ingress" {
  security_group_id        = aws_security_group.karpenter_nodes.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = module.eks.cluster_security_group_id
  description              = "Allow communication from EKS control plane to Karpenter nodes"
}

# Allow communication from managed node groups to Karpenter nodes
resource "aws_security_group_rule" "karpenter_nodes_managed_nodes_ingress" {
  security_group_id        = aws_security_group.karpenter_nodes.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = module.eks.node_security_group_id
  description              = "Allow communication from managed node groups to Karpenter nodes"
}

# Allow communication from Karpenter nodes to EKS control plane
resource "aws_security_group_rule" "cluster_karpenter_nodes_ingress" {
  security_group_id        = module.eks.cluster_security_group_id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.karpenter_nodes.id
  description              = "Allow communication from Karpenter nodes to EKS control plane"
}

# Allow communication from Karpenter nodes to managed node groups
resource "aws_security_group_rule" "managed_nodes_karpenter_nodes_ingress" {
  security_group_id        = module.eks.node_security_group_id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.karpenter_nodes.id
  description              = "Allow communication from Karpenter nodes to managed node groups"
}

resource "kubectl_manifest" "karpenter_gpu_nodeclass" {
  yaml_body = <<-YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu
spec:
  amiSelectorTerms:
  - alias: bottlerocket@latest
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
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 200Gi
        volumeType: gp3
        iops: 6000
        throughput: 1000
        deleteOnTermination: true
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_gpu_nodepool" {
  yaml_body = <<-YAML
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  template:
    metadata:
      labels:
        launch-type: karpenter
        node-class: gpu
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["g6e"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["2xlarge", "4xlarge", "8xlarge", "12xlarge", "24xlarge"]
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
  limits:
    "nvidia.com/gpu": 100
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 1m
  YAML

  depends_on = [kubectl_manifest.karpenter_gpu_nodeclass]
}

resource "kubectl_manifest" "karpenter_cpu_nodeclass" {
  yaml_body = <<-YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: cpu
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
        volumeSize: 150Gi
        volumeType: gp3
        iops: 6000
        throughput: 1000
        deleteOnTermination: true
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_cpu_nodepool" {
  yaml_body = <<-YAML
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: cpu
spec:
  template:
    metadata:
      labels:
        launch-type: karpenter
        node-class: cpu
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: cpu
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["c", "m", "r"]
        - key: "karpenter.k8s.aws/instance-cpu"
          operator: In
          values: ["4", "8", "16", "32"]
        - key: "karpenter.k8s.aws/instance-generation"
          operator: Gt
          values: ["6"]
  limits:
    cpu: 1000
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
  YAML

  depends_on = [kubectl_manifest.karpenter_cpu_nodeclass]
}
