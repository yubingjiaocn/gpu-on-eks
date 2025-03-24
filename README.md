# GPU on EKS Terraform Project

This Terraform project sets up an Amazon EKS cluster with GPU support and several key components:

1. EKS cluster with m7i-flex.xlarge nodes as a managed node group
2. AWS Load Balancer Controller
3. Karpenter with CPU and GPU node pools
4. EBS Throughput Tuner for optimizing EBS volume performance
5. Optional vLLM deployment using Mountpoint for S3 for model storage
6. Optional observability stack with Prometheus, DCGM Exporter, and Grafana
7. NVIDIA Device Plugin for Kubernetes

## Components

- **EKS Cluster**: A Kubernetes cluster with x86 m7i-flex.xlarge instances
- **AWS Load Balancer Controller**: For managing AWS load balancers for Kubernetes services
- **Karpenter**: Auto-scaling solution with separate node pools for CPU and GPU workloads
  - CPU Node Pool: Uses c/m/r instance types (AMD64) for general workloads
  - GPU Node Pool: Uses g6e instances for GPU workloads
- **EBS Throughput Tuner**: Automatically optimizes EBS volume performance for EC2 instances
- **vLLM Deployment**: Optional deployment of vLLM inference server using GPU nodes and S3 for model storage
- **Observability Stack**: Optional monitoring with Prometheus, DCGM Exporter for GPU metrics, and Grafana
- **NVIDIA Device Plugin**: Enables GPU support in Kubernetes with GPU Feature Discovery

## Key Features

- Uses latest Terraform AWS modules (as of March 2025)
- Implements EKS Pod Identity instead of IRSA for better security
- GPU metrics collection with DCGM Exporter
- Efficient model storage with Mountpoint for S3
- Leverages AWS GPU-optimized AMIs with pre-installed NVIDIA drivers

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.0
- kubectl

## Usage

1. Initialize the Terraform project:
   ```
   terraform init
   ```

2. Review the execution plan:
   ```
   terraform plan
   ```

3. Apply the configuration:
   ```
   terraform apply
   ```

4. Configure kubectl to use the new cluster:
   ```
   aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)
   ```

## Configuration

Adjust the variables in `variables.tf` to customize your deployment:

- `region`: AWS region to deploy resources (default: us-west-2)
- `cluster_name`: Name of the EKS cluster (default: gpu-eks-cluster)
- `cluster_version`: Kubernetes version for the EKS cluster (default: 1.31)
- `ebs_throughput`: EBS volume throughput in MB/s (default: 125)
- `ebs_iops`: EBS volume IOPS (default: 3000)
- `ebs_tuner_duration`: Duration to wait before tuning EBS volumes (default: 600)

### vLLM Configuration

To deploy vLLM, set the following variables:

- `deploy_vllm`: Set to `true` to deploy vLLM (default: `false`)
- `vllm_model_name`: Name of the model to use with vLLM (default: deepseek-ai/DeepSeek-R1-Distill-Llama-8B)
- `vllm_image`: Docker image for vLLM (default: vllm/vllm-openai:latest)

Example:
```
terraform apply -var="deploy_vllm=true" -var="vllm_model_name=deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
```

After deployment, you'll need to upload your model files to the created S3 bucket:
```
aws s3 cp --recursive /path/to/your/model s3://$(terraform output -raw vllm_model_storage_bucket)/deepseek-ai/DeepSeek-R1-Distill-Llama-8B/
```

### Observability Configuration

To enable the observability stack, set the following variables:

- `enable_observability`: Set to `true` to deploy Prometheus and DCGM Exporter (default: `true`)
- `deploy_grafana`: Set to `true` to deploy Grafana (default: `true`)

Example:
```
terraform apply -var="enable_observability=true" -var="deploy_grafana=true"
```

After deployment, you can access:
- Prometheus: Run `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090`
- Grafana: Access via the ALB URL (get with `kubectl get ingress -n monitoring kube-prometheus-stack-grafana`)
- Alertmanager: Run `kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093`

## EKS Pod Identity

This project uses EKS Pod Identity instead of IAM Roles for Service Accounts (IRSA):

- More secure: No need for OIDC provider or external-id
- Simplified: Direct association between pods and IAM roles
- Better auditing: Clearer connection between pod and role
- Future-proof: AWS's recommended approach going forward

## Karpenter Node Pools

The project includes two Karpenter node pools:

1. **CPU Node Pool**: Uses c/m/r instances (AMD64) for general workloads
2. **GPU Node Pool**: Uses g6e instances for GPU workloads

## Clean Up

To destroy all resources created by this project:

```
terraform destroy
```