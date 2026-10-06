# EKS Setup Commands

## Prerequisites

Verify the required tools are installed.

```bash
aws --version
kubectl version --client
eksctl version
helm version
```

---

# Configure AWS CLI

```bash
aws configure
```

Verify identity:

```bash
aws sts get-caller-identity
```

---

# Create EKS Cluster

```bash
eksctl create cluster \
  --name my-eks-cluster \
  --region us-east-1 \
  --nodegroup-name my-worker-node \
  --node-type t3.medium \
  --nodes 2
```

---

# Update kubeconfig

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name my-eks-cluster
```

Verify:

```bash
kubectl get nodes
kubectl get pods -A
```

---

# Associate IAM OIDC Provider

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster my-eks-cluster \
  --region us-east-1 \
  --approve
```

Verify:

```bash
aws eks describe-cluster \
  --name my-eks-cluster \
  --query "cluster.identity.oidc.issuer"
```

---

# Install Amazon EBS CSI Driver

```bash
eksctl create addon \
  --cluster my-eks-cluster \
  --name aws-ebs-csi-driver \
  --region us-east-1 \
  --force
```

Verify:

```bash
kubectl get pods -n kube-system | grep ebs
```

---

# Create IAM Policy for AWS Load Balancer Controller

```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

---

# Create IAM Service Account

```bash
eksctl create iamserviceaccount \
  --cluster=my-eks-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --region=us-east-1
```

Verify:

```bash
kubectl get sa -n kube-system aws-load-balancer-controller
```

---

# Add Helm Repository

```bash
helm repo add eks https://aws.github.io/eks-charts

helm repo update
```

---

# Install AWS Load Balancer Controller

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=<VPC-ID>
```

Verify:

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller

kubectl get pods -n kube-system | grep aws-load-balancer-controller
```

---

# Verify Metrics Server

```bash
kubectl get pods -n kube-system | grep metrics-server

kubectl top nodes

kubectl top pods -A
```

---

# Create Docker Registry Secret (Amazon ECR)

```bash
aws ecr get-login-password --region us-east-1 | \
kubectl create secret docker-registry ecr-registry-secret \
  --docker-server=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password-stdin \
  -n assignment-portal
```

Verify:

```bash
kubectl get secret -n assignment-portal
```

---

# Deploy Application

```bash
kubectl apply -f manifest_files/
```

or

```bash
kubectl apply -f manifest_files/config/

kubectl apply -f manifest_files/storage/

kubectl apply -f manifest_files/postgres/

kubectl apply -f manifest_files/redis/

kubectl apply -f manifest_files/backend/

kubectl apply -f manifest_files/frontend/

kubectl apply -f manifest_files/hpa/

kubectl apply -f manifest_files/ingress/
```

---

# Verify Resources

```bash
kubectl get all -n assignment-portal

kubectl get pods -n assignment-portal

kubectl get svc -n assignment-portal

kubectl get ingress -n assignment-portal

kubectl get pvc -n assignment-portal

kubectl get hpa -n assignment-portal
```

---

# Useful Debug Commands

```bash
kubectl describe pod <pod-name> -n assignment-portal

kubectl logs <pod-name> -n assignment-portal

kubectl logs <pod-name> --previous -n assignment-portal

kubectl describe ingress assignment-portal-ingress -n assignment-portal

kubectl describe hpa backend-hpa -n assignment-portal

kubectl get endpoints -n assignment-portal

kubectl top pods -n assignment-portal

kubectl top nodes
```

---

# Delete Application

```bash
kubectl delete namespace assignment-portal
```

---

# Uninstall AWS Load Balancer Controller

```bash
helm uninstall aws-load-balancer-controller -n kube-system
```

---

# Delete IAM Service Account

```bash
eksctl delete iamserviceaccount \
  --cluster my-eks-cluster \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --region us-east-1
```

---

# Delete EKS Cluster

```bash
eksctl delete cluster \
  --name my-eks-cluster \
  --region us-east-1
```
