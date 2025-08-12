################################################################################
# vLLM Deployment with EFS
################################################################################

resource "kubernetes_namespace" "vllm" {
  count = var.deploy_vllm ? 1 : 0

  metadata {
    name = "vllm"
  }

  depends_on = [module.eks]
}

# Create EFS file system for model storage
resource "aws_efs_file_system" "model_storage" {
  count = var.deploy_vllm ? 1 : 0

  creation_token = "${var.cluster_name}-model-storage"
  performance_mode = "generalPurpose"
  throughput_mode = "elastic"

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-model-storage"
  })
}

# Create EFS mount targets in each subnet
resource "aws_efs_mount_target" "model_storage" {
  count = var.deploy_vllm ? length(module.vpc.private_subnets) : 0

  file_system_id  = aws_efs_file_system.model_storage[0].id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs[0].id]
}

# Create security group for EFS
resource "aws_security_group" "efs" {
  count = var.deploy_vllm ? 1 : 0

  name        = "${var.cluster_name}-efs-sg"
  description = "Security group for EFS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-efs-sg"
  })
}

# Create ServiceAccount for vLLM
resource "kubernetes_service_account" "vllm_sa" {
  count = var.deploy_vllm ? 1 : 0

  metadata {
    name      = "vllm-sa"
    namespace = kubernetes_namespace.vllm[0].metadata[0].name
    # No annotations needed with EKS Pod Identity
  }

  depends_on = [kubernetes_namespace.vllm]
}

# Create PV for vLLM using EFS
resource "kubectl_manifest" "vllm_pv" {
  count = var.deploy_vllm ? 1 : 0

  yaml_body = <<-YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vllm-pv
spec:
  capacity:
    storage: 1000Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: efs.csi.aws.com
    volumeHandle: ${aws_efs_file_system.model_storage[0].id}
  YAML

  depends_on = [kubernetes_namespace.vllm, aws_efs_file_system.model_storage, aws_efs_mount_target.model_storage]
}

# Create PVC for vLLM
resource "kubectl_manifest" "vllm_pvc" {
  count = var.deploy_vllm ? 1 : 0

  yaml_body = <<-YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vllm-pvc
  namespace: ${kubernetes_namespace.vllm[0].metadata[0].name}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1000Gi
  volumeName: vllm-pv
  storageClassName: ""
  YAML

  depends_on = [kubectl_manifest.vllm_pv]
}

# Create vLLM Deployment
resource "kubectl_manifest" "vllm_deployment" {
  count = var.deploy_vllm ? 1 : 0

  yaml_body = <<-YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  namespace: ${kubernetes_namespace.vllm[0].metadata[0].name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
    spec:
      serviceAccountName: vllm-sa
      nodeSelector:
        karpenter.sh/nodepool: gpu
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: vllm
        image: ${var.vllm_image}
        resources:
          limits:
            nvidia.com/gpu: 1
          requests:
            memory: "16Gi"
            cpu: "4"
        args:
          - "--host"
          - "0.0.0.0"
          - "--port"
          - "8000"
          - "--model"
          - "${var.vllm_model_name}"
          - "--download-dir"
          - "/models"
          - "--trust-remote-code"
        ports:
        - containerPort: 8000
          name: http
        volumeMounts:
        - name: model-storage
          mountPath: /models
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: vllm-pvc
  YAML

  depends_on = [
    kubernetes_namespace.vllm,
    kubernetes_service_account.vllm_sa,
    kubectl_manifest.karpenter_gpu_nodepool,
    kubectl_manifest.vllm_pvc
  ]
}

# Create vLLM Service
resource "kubectl_manifest" "vllm_service" {
  count = var.deploy_vllm ? 1 : 0

  yaml_body = <<-YAML
apiVersion: v1
kind: Service
metadata:
  name: vllm-svc
  namespace: ${kubernetes_namespace.vllm[0].metadata[0].name}
spec:
  selector:
    app: vllm
  ports:
  - port: 8000
    targetPort: 8000
    protocol: TCP
    name: http
  type: ClusterIP
  YAML

  depends_on = [kubectl_manifest.vllm_deployment]
}

# Create Ingress for vLLM
resource "kubectl_manifest" "vllm_ingress" {
  count = var.deploy_vllm ? 1 : 0

  yaml_body = <<-YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-ingress
  namespace: ${kubernetes_namespace.vllm[0].metadata[0].name}
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vllm
            port:
              number: 8000
  YAML

  depends_on = [kubectl_manifest.vllm_service]
}

# vLLM outputs
output "vllm_model_storage_efs_id" {
  description = "EFS file system ID for vLLM model storage"
  value       = var.deploy_vllm ? aws_efs_file_system.model_storage[0].id : null
}

output "vllm_service_endpoint" {
  description = "Internal Endpoint for vLLM service"
  value       = var.deploy_vllm ? "http://${kubectl_manifest.vllm_service[0].name}.${kubernetes_namespace.vllm[0].metadata[0].name}.svc.cluster.local:8000" : null
}

output "vllm_model_name" {
  description = "Model name used for vLLM"
  value       = var.deploy_vllm ? var.vllm_model_name : null
}