################################################################################
# vLLM Deployment with Mountpoint for S3
################################################################################

resource "kubernetes_namespace" "vllm" {
  count = var.deploy_vllm ? 1 : 0

  metadata {
    name = "vllm"
  }

  depends_on = [module.eks]
}

# Create S3 bucket for model storage
resource "aws_s3_bucket" "model_storage" {
  count = var.deploy_vllm ? 1 : 0

  bucket = "${var.cluster_name}-model-storage"
  force_destroy = true

  tags = local.tags
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

# Create PV for vLLM
resource "kubectl_manifest" "vllm_pv" {
  count = var.deploy_vllm ? 1 : 0

  yaml_body = <<-YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vllm-pv
  namespace: ${kubernetes_namespace.vllm[0].metadata[0].name}
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: s3.csi.aws.com
    volumeHandle: vllm-pv
    volumeAttributes:
      bucketName: ${var.cluster_name}-model-storage
      mountOptions: "--allow-delete --allow-other --allow-overwrite --file-mode 777 --dir-mode 777 --incremental-upload"
  YAML

  depends_on = [kubernetes_namespace.vllm, aws_s3_bucket.model_storage]
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
      storage: 100Gi
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
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
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
