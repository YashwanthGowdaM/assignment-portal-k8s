#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

LOG_FILE="installation_versions.log"

# Function to format and output both to console and the output version log file
log_output() {
    echo "$1" | tee -a "$LOG_FILE"
}

# Initialize / Reset log file header
echo "==================================================" > "$LOG_FILE"
echo "        TOOL INSTALLATION & VERSION LOG           " >> "$LOG_FILE"
echo "        Generated on: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "==================================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

sudo apt -y update && sudo apt -y upgrade
sudo apt install -y unzip tree plocate

echo "=========================================="
echo "Phase 0: Tool Installation & Environment Setup"
echo "=========================================="

# 0. Set Hostname permanently
echo "[1/5] Setting hostname permanently to EKSClient..."
sudo hostnamectl set-hostname EKSClient
if ! grep -q "EKSClient" /etc/hosts; then
    echo "127.0.1.1 EKSClient" | sudo tee -a /etc/hosts > /dev/null
fi

# Adjust prompt to show directory basename (\W instead of \w) preserving color gradings
echo "[2/5] Configuring shell prompt path formatting..."
if grep -q '\\w' ~/.bashrc; then
    sed -i 's/\\w/\\W/g' ~/.bashrc
elif grep -q '\\\\w' ~/.bashrc; then
    sed -i 's/\\\\w/\\\\W/g' ~/.bashrc
fi
export PS1="${PS1//\\w/\\W}"

# 0.1 Install eksctl
if ! command -v eksctl &> /dev/null; then
    echo "[3/5] Installing eksctl..."
    ARCH=$(uname -s)
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_${ARCH}_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
else
    echo "[3/5] eksctl is already installed."
fi

EKSCTL_VER=$(eksctl version 2>&1 || true)
log_output "[TOOL] eksctl"
log_output "[VERSION] $EKSCTL_VER"
log_output "--------------------------------------------------"

# 0.2 Install kubectl
if ! command -v kubectl &> /dev/null; then
    echo "[4/5] Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mkdir -p ~/.local/bin
    mv ./kubectl ~/.local/bin/kubectl
    if ! grep -q "$HOME/.local/bin" ~/.bashrc; then
        echo 'export PATH=$PATH:$HOME/.local/bin' >> ~/.bashrc
    fi
    export PATH=$PATH:$HOME/.local/bin
else
    echo "[4/5] kubectl is already installed."
fi

KUBECTL_VER=$(kubectl version --client -o yaml 2>&1 || kubectl version --client 2>&1 || true)
log_output "[TOOL] kubectl"
log_output "[VERSION]"
log_output "$KUBECTL_VER"
log_output "--------------------------------------------------"

# 0.3 Install AWS CLI
if ! command -v aws &> /dev/null; then
    echo "[5/5] Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo ./aws/install
    rm -rf awscliv2.zip aws
else
    echo "[5/5] AWS CLI is already installed."
fi

AWS_VER=$(aws --version 2>&1 || true)
log_output "[TOOL] AWS CLI"
log_output "[VERSION] $AWS_VER"
log_output "--------------------------------------------------"

# 0.4 Configure AWS credentials
echo "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    echo "AWS credentials not configured or invalid. Please configure them:"
    aws configure
else
    echo "AWS credentials verified successfully:"
    CALLER_ID=$(aws sts get-caller-identity 2>&1)
    echo "$CALLER_ID"
    log_output "[IDENTITY] AWS Caller Identity"
    log_output "$CALLER_ID"
    log_output "=================================================="
fi

echo
echo "Phase 0 completed successfully! Version output saved to: $LOG_FILE"
echo "Starting EKS Cluster Creator..."
sleep 2

# ==========================================
# Phase 1: Amazon EKS Cluster Creator Menu
# ==========================================
while true
do
    clear

    echo "=========================================="
    echo "        Amazon EKS Cluster Creator"
    echo "=========================================="
    echo

    echo "1) Default Mode"
    echo "2) Custom Mode"
    echo "3) Exit"
    echo

    read -rp "Enter your choice [1-3]: " MODE

    case "$MODE" in

    1)
        export CLUSTER_NAME="my-eks-cluster"
        export NODEGROUP_NAME="my-worker-node"
        export NODE_TYPE="t2.micro"
        export NODE_COUNT=3
        export AWS_REGION="us-west-2"
        NODE_VOLUME_SIZE=""
        ;;

    2)
        read -rp "Cluster Name        : " CLUSTER_NAME
        read -rp "Node Group Name     : " NODEGROUP_NAME
        read -rp "EC2 Instance Type   : " NODE_TYPE
        read -rp "Number of Nodes     : " NODE_COUNT
        read -rp "AWS Region          : " AWS_REGION
        read -rp "Worker Root Volume Size (GB) [Press Enter to skip]: " NODE_VOLUME_SIZE

        export CLUSTER_NAME
        export NODEGROUP_NAME
        export NODE_TYPE
        export NODE_COUNT
        export AWS_REGION
        ;;

    3)
        echo "Goodbye."
        exit 0
        ;;

    *)
        echo "Invalid choice."
        sleep 2
        continue
        ;;
    esac

    echo
    echo "=========================================="
    echo "Configuration Summary"
    echo "=========================================="

    echo "Cluster Name : $CLUSTER_NAME"
    echo "Node Group   : $NODEGROUP_NAME"
    echo "Instance Type: $NODE_TYPE"
    echo "Node Count   : $NODE_COUNT"
    echo "Region       : $AWS_REGION"

    if [[ -n "$NODE_VOLUME_SIZE" ]]; then
        echo "Root Volume  : ${NODE_VOLUME_SIZE} GB"
    else
        echo "Root Volume  : Default"
    fi

    echo
    read -rp "Proceed with cluster creation? (y/n): " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo
        echo "Returning to main menu..."
        sleep 2
        continue
    fi

    CMD=(
        eksctl create cluster
        --name "$CLUSTER_NAME"
        --nodegroup-name "$NODEGROUP_NAME"
        --node-type "$NODE_TYPE"
        --nodes "$NODE_COUNT"
        --managed
        --region "$AWS_REGION"
    )

    if [[ -n "$NODE_VOLUME_SIZE" ]]; then
        CMD+=(--node-volume-size "$NODE_VOLUME_SIZE")
    fi

    "${CMD[@]}"

    break

done
