output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "karpenter_node_iam_role_arn" {
  description = "IAM Role ARN for Karpenter nodes"
  value       = module.karpenter.iam_role_arn
}


output "lambda_function_name" {
  description = "Name of the EBS throughput tuner Lambda function"
  value       = module.lambda_function.lambda_function_name
}

output "step_function_arn" {
  description = "ARN of the EBS throughput tuner Step Function"
  value       = module.step_function.state_machine_arn
}

# vLLM outputs
output "vllm_model_storage_bucket" {
  description = "S3 bucket for vLLM model storage"
  value       = var.deploy_vllm ? aws_s3_bucket.model_storage[0].bucket : null
}

output "vllm_service_endpoint" {
  description = "Endpoint for vLLM service"
  value       = var.deploy_vllm ? "http://${kubectl_manifest.vllm_service[0].name}.${kubernetes_namespace.vllm[0].metadata[0].name}.svc.cluster.local:8000" : null
}

output "vllm_model_name" {
  description = "Model name used for vLLM"
  value       = var.deploy_vllm ? var.vllm_model_name : null
}