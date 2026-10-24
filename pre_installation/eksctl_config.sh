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
