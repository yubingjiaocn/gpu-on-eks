provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_availability_zones" "available" {}

locals {
  name            = var.cluster_name
  cluster_version = var.cluster_version

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Environment = "dev"
    Terraform   = "true"
    Project     = "gpu-on-eks"
  }
}

################################################################################
# IAM Roles for EKS Add-ons with Pod Identity
################################################################################

# EBS CSI Driver IAM Role
# EBS CSI Driver IAM Role
resource "aws_iam_role" "ebs_csi_role" {
  name = "${local.name}-ebs-csi-role"

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

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# VPC CNI IAM Role
resource "aws_iam_role" "vpc_cni_role" {
  name = "${local.name}-vpc-cni-role"

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

resource "aws_iam_role_policy_attachment" "vpc_cni_policy" {
  role       = aws_iam_role.vpc_cni_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# S3 CSI Driver IAM Role
resource "aws_iam_role" "s3_csi_role" {
  name = "${local.name}-s3-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${module.eks.oidc_provider}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub": "system:serviceaccount:kube-system:mountpoint-s3-csi-controller-sa"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "s3_csi_policy" {
  role       = aws_iam_role.s3_csi_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name                   = local.name
  cluster_version                = local.cluster_version
  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    cpu_nodes = {
      name = "cpu-node-group"

      instance_types = ["m7i-flex.xlarge"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 2
      desired_size = 2

      tags = local.tags
    }
  }

  # Enable EKS Add-ons with Pod Identity
  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn = aws_iam_role.ebs_csi_role.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    coredns = {
      most_recent = true
      # CoreDNS doesn't require IAM permissions
    }
    kube-proxy = {
      most_recent = true
      # kube-proxy doesn't require IAM permissions
    }
    vpc-cni = {
      most_recent = true
      pod_identity_association = [{
        role_arn = aws_iam_role.vpc_cni_role.arn
        service_account = "aws-node"
      }]
    }
    # Enable EKS Pod Identity addon
    eks-pod-identity-agent = {
      most_recent = true
      before_compute = true
      # This add-on doesn't require IAM permissions
    }
    # Enable Amazon S3 CSI driver
    aws-mountpoint-s3-csi-driver = {
      most_recent = true
      service_account_role_arn = aws_iam_role.s3_csi_role.arn
      resolve_conflicts_on_create = "OVERWRITE"
      configuration_values = jsonencode({
        node = {
          tolerateAllTaints = true
        }
      })
    }
  }

  tags = local.tags
}

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "${local.name}-vpc"
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}

################################################################################
# AWS Load Balancer Controller with EKS Pod Identity
################################################################################

# Create IAM role for Load Balancer Controller
resource "aws_iam_role" "lb_controller_role" {
  name = "${local.name}-lb-controller-role"

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

# Create EKS Pod Identity Association for Load Balancer Controller
resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller_role.arn
}

# Attach Load Balancer Controller policy to the role
resource "aws_iam_policy" "lb_controller_policy" {
  name        = "${local.name}-lb-controller-policy"
  description = "Policy for AWS Load Balancer Controller"

  policy = data.http.lb_controller_policy.response_body

  tags = local.tags
}

data "http" "lb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.12.0/docs/install/iam_policy.json"
}

resource "aws_iam_role_policy_attachment" "lb_controller_policy_attachment" {
  role       = aws_iam_role.lb_controller_role.name
  policy_arn = aws_iam_policy.lb_controller_policy.arn
}

module "aws_load_balancer_controller" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "~> 1.1"

  name = "aws-load-balancer-controller"

  chart = "aws-load-balancer-controller"
  chart_version = "1.12.0"  # Latest chart version
  repository    = "https://aws.github.io/eks-charts"
  namespace     = "kube-system"

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
      }
    })
  ]

  depends_on = [module.eks, aws_eks_pod_identity_association.lb_controller]
}

resource "kubectl_manifest" "ebs_storage_class" {
  yaml_body = <<-YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-sc
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
reclaimPolicy: Delete
allowVolumeExpansion: true
YAML

  depends_on = [module.eks]
}