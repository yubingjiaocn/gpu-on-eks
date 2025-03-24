variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "gpu-eks-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "ebs_throughput" {
  description = "EBS volume throughput in MB/s for gp3 volumes"
  type        = number
  default     = 125
}

variable "ebs_iops" {
  description = "EBS volume IOPS for gp3 volumes"
  type        = number
  default     = 3000
}

variable "ebs_tuner_duration" {
  description = "Duration in seconds to wait before tuning EBS volumes"
  type        = number
  default     = 600
}

# vLLM Deployment Variables
variable "deploy_vllm" {
  description = "Whether to deploy vLLM"
  type        = bool
  default     = false
}

variable "vllm_model_name" {
  description = "Name of the model to use with vLLM (should be available in the S3 bucket)"
  type        = string
  default     = "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
}

variable "vllm_image" {
  description = "Docker image for vLLM"
  type        = string
  default     = "vllm/vllm-openai:latest"
}

# Observability Variables
variable "enable_observability" {
  description = "Whether to enable observability components (AMP, DCGM Exporter)"
  type        = bool
  default     = false
}

variable "deploy_grafana" {
  description = "Whether to deploy Amazon Managed Grafana for visualization"
  type        = bool
  default     = true
}