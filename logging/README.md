# Centralized Logging for the Assignment Portal — Fluent Bit → Splunk on EKS

A complete, beginner-friendly guide to collect **logs from every Deployment** in your EKS cluster
(backend, frontend, Redis, Postgres, ArgoCD, monitoring, …) and search them in **Splunk**.

Today your cluster only has **metrics** (Prometheus/Grafana). Metrics tell you *that* something is
wrong ("5xx rate went up"). Logs tell you *why* ("`psycopg2.OperationalError: connection refused`").
This guide adds the logs side.

> **Time needed:** about 60–90 minutes the first time.
> **You do not need prior Fluent Bit or Splunk knowledge.** Every command is given in order, with what you should see.

---

## Table of Contents

1. [How it works (read this first)](#1-how-it-works-read-this-first)
2. [Decisions: server size, disk size, cost](#2-decisions-server-size-disk-size-cost)
3. [Prerequisites](#3-prerequisites)
4. [Phase A — Create the Splunk server on AWS](#4-phase-a--create-the-splunk-server-on-aws)
5. [Phase B — Install and configure Splunk](#5-phase-b--install-and-configure-splunk)
6. [Phase C — Deploy Fluent Bit on EKS](#6-phase-c--deploy-fluent-bit-on-eks)
7. [Phase D — See your logs in Splunk](#7-phase-d--see-your-logs-in-splunk)
8. [What the Fluent Bit config does (and how to change it)](#8-what-the-fluent-bit-config-does-and-how-to-change-it)
9. [Troubleshooting](#9-troubleshooting)
10. [Hardening and next steps](#10-hardening-and-next-steps)
11. [Optional: deploy Fluent Bit with ArgoCD](#11-optional-deploy-fluent-bit-with-argocd)
12. [Cleanup](#12-cleanup)
13. [Glossary](#13-glossary)

---

## 1. How it works (read this first)

```
   EKS cluster (3 nodes)                                  Dedicated EC2 server (same VPC)
 ┌──────────────────────────────────────┐              ┌──────────────────────────────────┐
 │ Node 1                               │              │  Splunk Enterprise               │
 │  backend pods ──┐                    │              │                                  │
 │  frontend pods ─┼─► /var/log/        │   HTTPS      │  HEC (HTTP Event Collector)      │
 │  redis / pg ────┘   containers/*.log │   :8088      │  port 8088  ◄── token            │
 │        ▲                             │ ───────────► │        │                         │
 │        │ reads files                 │              │        ▼                         │
 │  Fluent Bit pod (DaemonSet)          │              │  index "k8s_logs"  (30 days)     │
 │                                      │              │        │                         │
 │ Node 2 … Fluent Bit pod              │              │  Splunk Web  :8000  ◄── you      │
 │ Node 3 … Fluent Bit pod              │              └──────────────────────────────────┘
 └──────────────────────────────────────┘
```

- Kubernetes writes everything a container prints (stdout and stderr) to a file on the node:
  `/var/log/containers/<pod>_<namespace>_<container>-<id>.log`.
- **Fluent Bit** is a tiny log collector. It runs as a **DaemonSet** (one pod on every node),
  reads those files, adds Kubernetes details (namespace, pod, labels, node) and sends the events on.
  Because it reads *all* files on the node, **every Deployment is covered automatically**, including ones you add later. You never edit your app manifests.
- **Splunk** stores and searches the logs. Fluent Bit sends to Splunk's **HEC** (HTTP Event Collector), which is
  just an HTTPS endpoint on port 8088 that accepts events when you present a secret **token**.
- Your own question — *"avoid Fluent Bit's own logs"* — is handled in two places:
  1. Fluent Bit never reads logs from the `logging` namespace where it lives (no feedback loop, nothing of its own in Splunk).
  2. Fluent Bit's own log level is set to `warn`, so it stays quiet.

**What is collected:** logs of every container in every namespace, except the `logging` namespace.
**What is *not* collected:** node OS/kubelet logs, EKS control-plane logs (those go to CloudWatch), and ALB access logs.

> **A note about "stderr":** many apps (Flask/gunicorn included) write their *normal* logs to stderr.
> So dropping stderr would hide real app logs. By default this setup keeps both stdout and stderr and only removes
> Fluent Bit's own logs and health-check noise. If you really want to drop stderr, see
> [section 8.2](#82-common-changes).

---

## 2. Decisions: server size, disk size, cost

### 2.1 Do I need a dedicated server for Splunk?

**Yes, use a dedicated EC2 instance** (outside the cluster). Reasons:
- Splunk needs a lot more memory and fast disk than your 3 × `t3.medium` nodes can spare
  (those nodes already run the app, Prometheus and Grafana).
- If the cluster has a problem, your logs are still available to investigate it.

Put it **in the same VPC as your EKS cluster**, so Fluent Bit reaches it on a private IP (free, fast, and never exposed to the internet).
This guide does exactly that.

### 2.2 Instance type

Splunk is a single-server install here (indexing + search on one box).

| Scenario | Log volume per day | Instance type | vCPU / RAM | Root disk | Data disk |
|---|---|---|---|---|---|
| Learning / lab only | under 1 GB | `t3.large` | 2 / 8 GB | 30 GB gp3 | 50 GB gp3 |
| **Recommended for this project** | **1 – 5 GB** | **`t3.xlarge`** (or `m5.xlarge` for steady load) | **4 / 16 GB** | **30 GB gp3** | **100 GB gp3** |
| Busier cluster | 5 – 20 GB | `m5.2xlarge` | 8 / 32 GB | 30 GB gp3 | 300 GB+ gp3 |
| Above ~20 GB/day | — | Needs a multi-server Splunk design; out of scope here | | | |

Notes:
- **x86 only.** Choose `t3`/`m5`/`m6i`, **not** Graviton (`t4g`, `m6g`) types.
- `t3` instances are *burstable*: fine for this size, but if Splunk is busy all day, an `m5.xlarge` is steadier.
- This table is my sizing guidance for a single-server install, not an official Splunk number (Splunk's published requirements page gives no CPU/RAM minimum; it points to its Capacity Planning Manual).
- **OS:** Ubuntu **22.04 or 24.04** (both officially supported by Splunk Enterprise). This guide uses 24.04.

### 2.3 Disk size

Splunk stores logs compressed plus an index; a good rule of thumb is that **stored size ≈ 50 % of the raw log size**.

```
Disk needed (GB)  =  logs per day (GB)  ×  days to keep  ×  0.5  ×  1.2 (headroom)
```

| Logs / day | Keep | Calculation | Round up to |
|---|---|---|---|
| 1 GB | 30 days | 1 × 30 × 0.5 × 1.2 = 18 GB | 50 GB |
| 3 GB | 30 days | 3 × 30 × 0.5 × 1.2 = 54 GB | 100 GB |
| 5 GB | 30 days | 5 × 30 × 0.5 × 1.2 = 90 GB | 150 GB |

- Use a **separate data disk** mounted at `/opt/splunk` (the script does this). Your logs then survive re-installing the OS or resizing the root disk, and you can snapshot just the data.
- **gp3** is the right EBS type (cheap, 3000 IOPS baseline).
- Splunk **stops indexing when free disk drops below ~5 GB**, so never fill the disk. The script caps the index size (`INDEX_MAX_GB`, default 80 GB for a 100 GB disk) and deletes events older than `RETENTION_DAYS` (default 30).

**How much will *my* cluster produce?** I can't know your exact number: it depends on traffic and log level. Your ConfigMap has `FLASK_ENV: "development"`, which tends to log more than production mode. Start with the recommended size, then measure after one day (SPL query in [7.4](#74-check-how-much-you-are-ingesting-daily)) and adjust.

### 2.4 Splunk license (important)

- A fresh Splunk Enterprise install starts with a **60-day trial license**.
- After it expires you need a license. Splunk Free exists but is limited to **500 MB/day**, has **no login/users**, and disables alerting. Splunk's docs I read do not say whether HEC works on Free, so confirm that before relying on it.
- You can see your daily cap in Splunk Web under **Settings → Licensing** after install.
- If your cluster produces more than the cap, you'll get license warnings. Use [section 8.2](#82-common-changes) to cut volume (e.g. skip `kube-system`/`monitoring`).

### 2.5 Approximate monthly cost (us-east-1, On-Demand, running 24×7)

Check the [AWS pricing page](https://aws.amazon.com/ec2/pricing/on-demand/) — these are rough figures.

| Item | Approx. |
|---|---|
| `t3.large` | ~$61 / month |
| `t3.xlarge` | ~$121 / month |
| `m5.xlarge` | ~$140 / month |
| 130 GB of gp3 (30 root + 100 data) | ~$10 / month |

Cost tip for a learning setup: **stop the instance** when you're not using it (you pay only for the disks). Your data stays. Fluent Bit buffers on the nodes meanwhile (up to 500 MB each) and catches up when Splunk is back.

### 2.6 Impact on your existing nodes

Fluent Bit asks for only `50m` CPU / `64Mi` memory per node (limit `200m` / `200Mi`). That's small, but check two
limits on `t3.medium` nodes:

- **Max 17 pods per node.** Your app + Prometheus stack + ArgoCD may already be close. Check in [6.1](#61-check-the-nodes-have-room).
- **10 GB node disk.** Fluent Bit keeps a disk buffer of **at most 500 MB** per node (set in the config). If your nodes are tight on disk, grow the node group volume to 20 GB.

---

## 3. Prerequisites

### 3.1 Checklist

| # | What | Why |
|---|---|---|
| 1 | AWS account permissions to create EC2 instances, volumes and security groups | Splunk server |
| 2 | `aws` CLI v2, configured (`aws configure`) | Create the server |
| 3 | `kubectl`, pointed at your cluster | Deploy Fluent Bit |
| 4 | An SSH client | Log in to the Splunk server |
| 5 | A free Splunk account (splunk.com) | Download the Splunk installer |
| 6 | Your EKS cluster running (`my-eks-cluster`, `us-east-1`) | Where Fluent Bit runs |

Your existing runbook (`pre_installation/01.DeploymentSetUp.md`) already covers installing/configuring the AWS CLI and kubectl. If you're on a fresh machine, here's the short version for Linux x86_64:

```bash
# AWS CLI v2
curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl

# SSH client (Ubuntu/Debian)
sudo apt-get update && sudo apt-get install -y openssh-client unzip curl
```

### 3.2 Verify everything works

```bash
aws sts get-caller-identity                       # shows your AWS account/user
aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster
kubectl get nodes                                 # should list your 3 nodes as Ready
```

**Expected:** `kubectl get nodes` prints 3 nodes with `STATUS Ready`. If not, fix that first (see your runbook, section 0.6).

### 3.3 Put the files in your repo

Copy this `logging/` folder to the **root of your `assignment-portal-k8s` repo**, next to `manifest_files/`:

```text
assignment-portal-k8s/
├── manifest_files/            # synced by ArgoCD (unchanged)
├── logging/                   # ← NEW (this folder)
│   ├── README.md
│   ├── fluent-bit/
│   │   ├── 00-namespace.yaml
│   │   ├── 01-rbac.yaml
│   │   ├── 02-configmap.yaml
│   │   └── 03-daemonset.yaml
│   └── splunk-server/
│       └── bootstrap-splunk.sh
└── ...
```

> **Why not inside `manifest_files/`?** Your ArgoCD Application syncs `manifest_files/` recursively with `prune: true`.
> Keeping logging outside means ArgoCD won't touch it until you choose to ([section 11](#11-optional-deploy-fluent-bit-with-argocd)),
> and you can learn the steps by hand first.

---

## 4. Phase A — Create the Splunk server on AWS

You can use the AWS Console, but the CLI below is repeatable. Run these in the same shell, in order.

### 4.1 Collect network details from your cluster

```bash
export AWS_REGION=us-east-1
export CLUSTER_NAME=my-eks-cluster

# The VPC your EKS cluster lives in, and its address range
export VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
export VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $AWS_REGION \
  --query 'Vpcs[0].CidrBlock' --output text)

# A PUBLIC subnet in that VPC (so you can open Splunk Web from your laptop)
export SUBNET_ID=$(aws ec2 describe-subnets --region $AWS_REGION \
  --filters Name=vpc-id,Values=$VPC_ID Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[0].SubnetId' --output text)

# Your own public IP, so only YOU can reach SSH and Splunk Web
export MY_IP=$(curl -s https://checkip.amazonaws.com)

echo "VPC=$VPC_ID  CIDR=$VPC_CIDR  SUBNET=$SUBNET_ID  MY_IP=$MY_IP"
```

**Expected:** all four values are filled in (e.g. `VPC=vpc-0abc… CIDR=192.168.0.0/16 SUBNET=subnet-0def… MY_IP=203.0.113.7`).
If `SUBNET` shows `None`, open the VPC console, pick a subnet whose route table has an Internet Gateway, and set `SUBNET_ID` by hand.

### 4.2 Create the firewall (security group)

```bash
export SG_ID=$(aws ec2 create-security-group --region $AWS_REGION \
  --group-name splunk-server-sg --description "Splunk server" --vpc-id $VPC_ID \
  --query GroupId --output text)

# SSH + Splunk Web: ONLY from your IP
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SG_ID \
  --protocol tcp --port 22   --cidr ${MY_IP}/32
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SG_ID \
  --protocol tcp --port 8000 --cidr ${MY_IP}/32

# HEC (log intake): ONLY from inside the VPC (your EKS nodes)
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SG_ID \
  --protocol tcp --port 8088 --cidr $VPC_CIDR

echo "Security group: $SG_ID"
```

| Port | Open to | Purpose |
|---|---|---|
| 22 | your IP only | SSH |
| 8000 | your IP only | Splunk Web (where you search logs) |
| 8088 | VPC only | HEC — Fluent Bit sends logs here |

> Never open 8088 to `0.0.0.0/0`. Anyone with the token could write to your Splunk.
> If your home IP changes, re-run the two `authorize-…` commands for 22/8000 with the new IP.

### 4.3 Create an SSH key

```bash
aws ec2 create-key-pair --region $AWS_REGION --key-name splunk-key \
  --query KeyMaterial --output text > splunk-key.pem
chmod 400 splunk-key.pem
```

Keep `splunk-key.pem` safe — it's the only way in over SSH.

### 4.4 Launch the instance

```bash
# Latest Ubuntu 24.04 AMI, looked up from AWS's official parameter
export AMI_ID=$(aws ssm get-parameter --region $AWS_REGION \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)

export INSTANCE_ID=$(aws ec2 run-instances --region $AWS_REGION \
  --image-id $AMI_ID \
  --instance-type t3.xlarge \
  --key-name splunk-key \
  --subnet-id $SUBNET_ID \
  --security-group-ids $SG_ID \
  --associate-public-ip-address \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[
    {"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30, "VolumeType":"gp3","DeleteOnTermination":true}},
    {"DeviceName":"/dev/sdf", "Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=splunk-server}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --region $AWS_REGION --instance-ids $INSTANCE_ID

export SPLUNK_PUBLIC_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
export SPLUNK_PRIVATE_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "Public: $SPLUNK_PUBLIC_IP   Private: $SPLUNK_PRIVATE_IP"
```

What you chose here (change to match [section 2](#2-decisions-server-size-disk-size-cost)): `t3.xlarge`, **30 GB** root, **100 GB** data (`/dev/sdf`).
`HttpTokens=required` turns on the more secure IMDSv2.

> **The public IP changes if you stop/start the instance.** The *private* IP does not, and Fluent Bit uses the private IP, so logging keeps working.
> To keep a fixed public address for Splunk Web, allocate an Elastic IP and associate it
> (`aws ec2 allocate-address` / `associate-address`), or just re-run the `describe-instances` command above.

### 4.5 Log in

Give it ~1 minute to finish booting, then:

```bash
ssh -i splunk-key.pem ubuntu@$SPLUNK_PUBLIC_IP
```

**Expected:** an Ubuntu welcome banner and a prompt `ubuntu@ip-…:~$`. (If it times out: your IP changed, or the subnet isn't public — recheck 4.1/4.2.)

Confirm the extra disk is attached (you're still logged into the server):

```bash
lsblk
```

**Expected:** a small-ish disk with partitions (root, 30 GB) and a second, **unpartitioned** disk of 100 GB (named like `nvme1n1`).

---

## 5. Phase B — Install and configure Splunk

### 5.1 Get the Splunk download link (on your laptop browser)

1. Create/sign in to a free account at **splunk.com**.
2. Go to **splunk.com/download** and pick **Splunk Enterprise** (menu names on the website change from time to time).
3. Choose **Linux**, then the **`.deb`** package (64-bit).
4. Click **"Download Now"** and in the dialog choose **"Command Line (wget)"**. Copy the whole `wget …` line and take just the **URL** inside the quotes.

It looks like `https://download.splunk.com/products/splunk/releases/<version>/linux/splunk-<version>-<build>-linux-amd64.deb` — do **not** type it by hand; the build part changes with each release.

> The link is shown to you on splunk.com and may expire after a while. If the download later fails with 403/404, just copy a fresh link.

### 5.2 Copy the script to the server

From your **laptop** (new terminal, in the folder where `splunk-key.pem` is, with `$SPLUNK_PUBLIC_IP` still set — or paste the IP):

```bash
scp -i splunk-key.pem logging/splunk-server/bootstrap-splunk.sh ubuntu@$SPLUNK_PUBLIC_IP:~/
```

### 5.3 Run it (on the server)

SSH back in (`ssh -i splunk-key.pem ubuntu@$SPLUNK_PUBLIC_IP`) and run — put your own link and password in:

```bash
export SPLUNK_DEB_URL='PASTE-THE-URL-FROM-STEP-5.1-HERE'
export SPLUNK_ADMIN_PASSWORD='Choose-A-Strong-Password-8plus'

sudo -E bash bootstrap-splunk.sh
```

> `-E` passes your two variables through `sudo`. Single quotes stop the shell from mangling special characters in the password.
>
> Index size and retention are settings too (defaults: 80 GB cap, 30 days — sized for the 100 GB disk).
> If you chose the 50 GB lab disk, lower them, for example:
> `sudo -E INDEX_MAX_GB=40 RETENTION_DAYS=14 bash bootstrap-splunk.sh`

**What the script does, in order** (so nothing is a black box):

| Step | Action |
|---|---|
| 1/6 | Formats the empty 100 GB disk (ext4) and mounts it at `/opt/splunk`, also in `/etc/fstab` so it survives reboots |
| 2/6 | Downloads and installs the Splunk `.deb` |
| 3/6 | Creates an app `k8s_logging` containing: the `k8s_logs` index, the HEC input + token, and a JSON-parsing rule |
| 4/6 | Sets the `admin` password and file permissions |
| 5/6 | Enables start-on-boot (systemd service `Splunkd`) and starts Splunk |
| 6/6 | Waits until Splunk Web and HEC are healthy, then prints the values you need |

It's safe to run again; it skips finished steps and keeps the same token. It will **never** reformat a disk that already has a filesystem.

**Expected final output** (takes 2–5 minutes):

```text
=============================================================================
 Splunk is ready.

 Web UI      : http://<this-server-public-IP>:8000     user: admin
 HEC health  : OK (https://10.0.x.x:8088)
 Index       : k8s_logs  (kept 30 days, max 80 GB)

 Values for Fluent Bit (also saved in /root/splunk-hec-info.txt, root-only):
     SPLUNK_HOST=10.0.x.x
     SPLUNK_PORT=8088
     SPLUNK_HEC_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
=============================================================================
```

**Copy those three lines** — you need them in step 6.2. (Lost them? `sudo cat /root/splunk-hec-info.txt`.)

### 5.4 Open Splunk Web

In your browser: `http://<SPLUNK_PUBLIC_IP>:8000` → log in as **admin** with the password you chose.
Accept any "first run" pop-ups. Then check **Settings → Licensing**: you should see the trial license and its daily limit.

### 5.5 Test the log intake before touching Kubernetes

On the Splunk server (so we know Splunk is good *before* Fluent Bit is involved):

```bash
source <(sudo sed 's/^/export /' /root/splunk-hec-info.txt)
curl -k https://127.0.0.1:8088/services/collector/event \
  -H "Authorization: Splunk $SPLUNK_HEC_TOKEN" \
  -d '{"event":"hello from curl","sourcetype":"manual"}'
```

**Expected:** `{"text":"Success","code":0}`
Now in Splunk Web → **Search & Reporting**, search `index=k8s_logs "hello from curl"` (time range *Last 15 minutes*). You should see your test event.

---

## 6. Phase C — Deploy Fluent Bit on EKS

Run these on the machine where `kubectl` works, from the root of your repo.

### 6.1 Check the nodes have room

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,MAX_PODS:.status.allocatable.pods
kubectl get pods -A --no-headers -o custom-columns=NODE:.spec.nodeName | sort | uniq -c
```

**Expected:** each node can hold 17 pods (`t3.medium`), and the count per node is **below ~16**. If a node is already at 17, the Fluent Bit pod on that node will stay `Pending` — remove something, or add a node (`eksctl scale nodegroup …`, see your runbook 0.7).

### 6.2 Create the namespace and the secret

```bash
kubectl apply -f logging/fluent-bit/00-namespace.yaml
```

Create the Secret holding the Splunk address and token (**paste your three values from step 5.3**):

```bash
kubectl create secret generic splunk-hec -n logging \
  --from-literal=SPLUNK_HOST='10.0.x.x' \
  --from-literal=SPLUNK_PORT='8088' \
  --from-literal=SPLUNK_HEC_TOKEN='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

> The token is a password. Creating the Secret with a command (not a YAML file) keeps it **out of Git**.
> `SPLUNK_HOST` must be the Splunk server's **private** IP.

### 6.3 Check the cluster can reach Splunk

This runs a short-lived pod inside the cluster and calls Splunk's health URL:

```bash
kubectl run net-test -n logging --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sk --max-time 10 https://10.0.x.x:8088/services/collector/health
```

(Use your private IP.) **Expected:** `{"text":"HEC is healthy","code":17}`

If it hangs or fails, the security group isn't allowing the cluster in — go to [Troubleshooting 9.1](#91-fluent-bit-pods-wont-start-or-cant-send).

### 6.4 Apply the rest

```bash
kubectl apply -f logging/fluent-bit/01-rbac.yaml
kubectl apply -f logging/fluent-bit/02-configmap.yaml
kubectl apply -f logging/fluent-bit/03-daemonset.yaml
```

### 6.5 Verify

```bash
kubectl get ds -n logging
kubectl get pods -n logging -o wide
```

**Expected:**

```text
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
fluent-bit   3         3         3       3            3

NAME               READY   STATUS    NODE
fluent-bit-xxxxx   1/1     Running   ip-…  (one per node, 3 in total)
```

Look at Fluent Bit's own messages (you read these here, in your terminal — they are deliberately **not** shipped to Splunk):

```bash
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=20
```

**Expected:** few or no lines (the level is `warn`). Lines containing `[error]` mean something is wrong → section 9.

---

## 7. Phase D — See your logs in Splunk

### 7.1 First search

In Splunk Web → **Search & Reporting**, time range **Last 15 minutes**:

```spl
index=k8s_logs
```

You should see events within a minute or so. Click an event to expand it; you'll see fields such as:

| Field | Example |
|---|---|
| `log` | `127.0.0.1 - - "GET /api/assignments HTTP/1.1" 200 …` |
| `stream` | `stdout` or `stderr` |
| `kubernetes.namespace_name` | `assignment-portal` |
| `kubernetes.pod_name` | `backend-6d9f7c-abcde` |
| `kubernetes.container_name` | `backend` |
| `kubernetes.labels.app` | `backend` |
| `host` | the node name (e.g. `ip-192-168-12-34.ec2.internal`) |
| `cluster` | `my-eks-cluster` |

### 7.2 Useful searches

```spl
# All logs from your app
index=k8s_logs kubernetes.namespace_name="assignment-portal"

# Only the backend
index=k8s_logs kubernetes.labels.app=backend

# Errors in your app
index=k8s_logs kubernetes.namespace_name="assignment-portal" (ERROR OR Exception OR Traceback OR "status=5*")

# Log volume per app over time (a chart: use the Visualization tab)
index=k8s_logs | timechart span=5m count by kubernetes.labels.app

# Which namespaces are noisiest?
index=k8s_logs | stats count by kubernetes.namespace_name | sort - count
```

### 7.3 Prove your "no Fluent Bit logs" requirement

```spl
index=k8s_logs kubernetes.namespace_name="logging"
```

**Expected: 0 events.** (Fluent Bit's own logs are never collected.)

### 7.4 Check how much you are ingesting daily

```spl
index=_internal source=*license_usage.log* type=Usage
| eval GB = b/1024/1024/1024
| timechart span=1d sum(GB) AS "GB per day"
```

Compare it with the table in [2.3](#23-disk-size) and your license cap in **Settings → Licensing**. Come back and adjust disk/instance/filters if it's much higher or lower than expected.
Also look at **Settings → Indexes** to see `k8s_logs` size on disk.

### 7.5 Save a dashboard (optional)

Run a search such as the "Log volume per app" one → **Save As → Dashboard Panel**. This gives you a logs panel next to the Grafana metrics you already have.

---

## 8. What the Fluent Bit config does (and how to change it)

### 8.1 The pipeline in `02-configmap.yaml`

Logs flow **INPUT → FILTERs → OUTPUT**:

| Block | What it does |
|---|---|
| `[SERVICE]` | Global settings. `Log_Level warn` keeps Fluent Bit's own output quiet. A disk buffer is enabled, so if Splunk is down for a while, logs wait on the node and are delivered later. |
| `[INPUT] tail` | Reads `/var/log/containers/*.log` (every container on the node). `Exclude_Path …_logging_…` skips the `logging` namespace = Fluent Bit's own logs. The `cri` multiline parser understands containerd's log format and keeps stack traces as one event. A small database remembers read positions so a restart doesn't re-send or lose logs. |
| `[FILTER] grep` | Drops health-check noise: lines containing `kube-probe` (your Kubernetes probes on `/health` and `/`) and `ELB-HealthChecker` (the ALB). Without this, probes hit every 10–20 s per pod and flood Splunk. |
| `[FILTER] kubernetes` | Adds namespace, pod, container, labels and node by asking the Kubernetes API. If an app prints JSON logs, it's split into searchable fields. |
| `[FILTER] modify` | Adds `cluster=my-eks-cluster`. |
| `[OUTPUT] splunk` | Sends events over HTTPS to HEC with gzip, into index `k8s_logs`, sourcetype `kube:container`, with `host` = node name. Retries until Splunk is back; the disk buffer is capped at 500 MB per node. |

### 8.2 Common changes

After editing `02-configmap.yaml`, always apply and restart:

```bash
kubectl apply -f logging/fluent-bit/02-configmap.yaml
kubectl rollout restart ds/fluent-bit -n logging
```

**Collect only your app (cuts volume a lot).** In `[INPUT]`, change `Path` to:

```ini
Path    /var/log/containers/*_assignment-portal_*.log
```

**Skip noisy system namespaces but keep everything else.** Change `Exclude_Path` to a comma-separated list:

```ini
Exclude_Path  /var/log/containers/*_logging_*.log,/var/log/containers/*_kube-system_*.log,/var/log/containers/*_monitoring_*.log
```

**Drop stderr** (careful — Flask often logs to stderr): uncomment the second `[FILTER] grep` block (the one with `Exclude stream stderr`).

**Exclude one specific Deployment** with no config change: add this annotation to the *pod template* of that Deployment:

```yaml
spec:
  template:
    metadata:
      annotations:
        fluentbit.io/exclude: "true"
```

**Drop extra noise lines**, e.g. also drop `GET /metrics` (Prometheus scrapes every 30 s): change the grep line to

```ini
Exclude   log (kube-probe|ELB-HealthChecker|GET /metrics)
```

**Change the index / retention.** Index name: `Event_Index` in the ConfigMap must match the index in Splunk. Retention: edit
`frozenTimePeriodInSecs` in `/opt/splunk/etc/apps/k8s_logging/local/indexes.conf` on the server, then `sudo systemctl restart Splunkd`.

**Different cluster name label:** set `CLUSTER_NAME` in `03-daemonset.yaml`.

---

## 9. Troubleshooting

Always start with Fluent Bit's messages, then Splunk's:

```bash
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=50          # Fluent Bit side
sudo tail -n 50 /opt/splunk/var/log/splunk/splunkd.log                          # Splunk side (on the server)
```

### 9.1 Fluent Bit pods won't start, or can't send

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod `CreateContainerConfigError` | Secret `splunk-hec` missing | Redo step 6.2; `kubectl get secret -n logging` |
| Pod `Pending`, event says `Too many pods` | Node already has 17 pods | Free a slot or add a node (6.1) |
| `CrashLoopBackOff`, log shows `[error] [config]` | Typo in the ConfigMap | Check indentation (4 spaces) and spelling; re-apply + restart |
| `[error] [http_client] broken connection to 10.x.x.x:8088` or `connection timed out` | Security group blocks 8088, wrong IP, or Splunk is stopped | Run the 6.3 test; verify the `SPLUNK_HOST` is the **private** IP; check the SG rule for 8088 is `$VPC_CIDR`; check Splunk is running |
| `HTTP status=403` / `Invalid token` | Wrong or disabled token | Compare with `sudo cat /root/splunk-hec-info.txt`; recreate the Secret (below) |
| `HTTP status=400` / `Incorrect index` | Index doesn't exist or token isn't allowed to use it | In Splunk: Settings → Indexes has `k8s_logs`; the HEC token's allowed indexes include it |
| TLS / handshake errors | `TLS On` but HEC set to plain HTTP (or the reverse) | HEC defaults to HTTPS in this guide; keep `TLS On` |

Changing the Secret (new token/IP) requires restarting the pods, because environment variables are read at start:

```bash
kubectl delete secret splunk-hec -n logging
kubectl create secret generic splunk-hec -n logging \
  --from-literal=SPLUNK_HOST='…' --from-literal=SPLUNK_PORT='8088' --from-literal=SPLUNK_HEC_TOKEN='…'
kubectl rollout restart ds/fluent-bit -n logging
```

### 9.2 Pods run, but no data in Splunk

1. Wait 1–2 minutes (Flush interval + startup).
2. Search over a wide time range: `index=k8s_logs earliest=-24h`.
3. Look at Fluent Bit's counters:
   ```bash
   kubectl port-forward -n logging ds/fluent-bit 2020:2020 &
   curl -s localhost:2020/api/v1/metrics | python3 -m json.tool | grep -E '"(proc_records|errors|retries|retries_failed)"'
   kill %1
   ```
   `proc_records` rising and `errors` at 0 = healthy. Rising `retries` = Splunk unreachable or rejecting.
4. Ask Splunk whether it is rejecting events: search `index=_internal source=*splunkd.log* component=HttpInputDataHandler`.
5. Filters too strict? Temporarily remove the `grep` filter, apply, restart.

### 9.3 Splunk problems

| Symptom | Fix |
|---|---|
| Splunk Web unreachable | Is the instance running? Did your IP change? (re-add it to SG ports 22/8000). Public IP changes after stop/start — re-run the `describe-instances` command in 4.4 |
| After server reboot, Splunk is down | `sudo systemctl status Splunkd`; start it with `sudo systemctl start Splunkd` (it's enabled on boot) |
| Indexing stopped, "low disk space" | Disk below ~5 GB free: expand the EBS volume (AWS console → Modify volume), then on the server run `lsblk` to find the data disk (the one mounted at `/opt/splunk`) and `sudo resize2fs <that device>`; or lower `RETENTION_DAYS` / `INDEX_MAX_GB` |
| License warnings / search disabled | You exceeded the daily cap: reduce volume (8.2), or use a proper license. Check usage with 7.4 |
| Script failed at download | The link expired — get a fresh one (5.1) and re-run; the script resumes safely |
| `Authentication failed` on login | You can reset: `sudo -u splunk /opt/splunk/bin/splunk edit user admin -password 'NewPass123' -auth admin:OldPass` |

### 9.4 Useful one-liners

```bash
kubectl get pods -n logging -o wide                              # one pod per node?
kubectl describe ds fluent-bit -n logging | tail -20             # events
kubectl get nodes -o wide                                        # node list
# Note: the Fluent Bit image has no shell, so `kubectl exec ... sh/ls` will not work. Use logs + metrics (9.2).
```

---

## 10. Hardening and next steps

This guide gets you a working, reasonably safe lab/demo. Before treating it as production:

1. **Verify HEC's TLS certificate.** Out of the box Splunk uses a self-signed certificate, so the config has `TLS.Verify Off`. Traffic is still encrypted and stays inside your VPC, but the identity of the server isn't checked. For production: install a certificate from your own CA on Splunk (HEC and Web), mount the CA in the Fluent Bit pod, set `TLS.CA_File`, and change to `TLS.Verify On`.
2. **Splunk Web over HTTPS** and behind a VPN or a private subnet using AWS Systems Manager Session Manager, instead of a public IP.
3. **Secrets:** move the HEC token from a plain Kubernetes Secret into AWS Secrets Manager (External Secrets Operator).
4. **Backups:** schedule EBS snapshots of the data volume (Amazon Data Lifecycle Manager).
5. **Pin and update:** Fluent Bit is pinned to `4.2.4`. Check [Docker Hub](https://hub.docker.com/r/fluent/fluent-bit/tags) for newer releases and test before bumping. Keep Splunk patched too.
6. **Alerts:** Splunk can alert on log patterns (not on Splunk Free). You can also keep alerting in Prometheus/Alertmanager and use Splunk for investigation.
7. **Log less, log better:** set `FLASK_ENV` to a production mode when you deploy for real; it reduces volume and noise.
8. **Node and control-plane logs** (kubelet, EKS API server) are not collected here. Add a second `tail`/`systemd` input, or enable EKS control-plane logging to CloudWatch.

---

## 11. Optional: deploy Fluent Bit with ArgoCD

Once you're comfortable, you can let ArgoCD manage the Fluent Bit files too (GitOps). The Splunk **Secret is not in Git**, so create it first (step 6.2), then add this Application next to your existing one:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: logging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YashwanthGowdaM/assignment-portal-k8s.git
    targetRevision: main
    path: logging/fluent-bit
  destination:
    server: https://kubernetes.default.svc
    namespace: logging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply it with `kubectl apply -f <file>.yaml`. From then on, changing `02-configmap.yaml` in Git is enough — but ConfigMap changes still need a pod restart (`kubectl rollout restart ds/fluent-bit -n logging`) because Fluent Bit reads its config at start.

---

## 12. Cleanup

Remove the log collector from the cluster:

```bash
kubectl delete -f logging/fluent-bit/03-daemonset.yaml
kubectl delete -f logging/fluent-bit/02-configmap.yaml
kubectl delete -f logging/fluent-bit/01-rbac.yaml
kubectl delete secret splunk-hec -n logging
kubectl delete -f logging/fluent-bit/00-namespace.yaml
```

The nodes keep a small folder `/var/fluent-bit/state` (read positions + buffer). It's harmless and can be reused if you redeploy.

Remove the Splunk server (**this deletes all stored logs** — both disks were created with delete-on-termination):

```bash
aws ec2 terminate-instances --region $AWS_REGION --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --region $AWS_REGION --instance-ids $INSTANCE_ID
aws ec2 delete-security-group --region $AWS_REGION --group-id $SG_ID
aws ec2 delete-key-pair --region $AWS_REGION --key-name splunk-key
rm -f splunk-key.pem
# If you created an Elastic IP: aws ec2 release-address --allocation-id <id>
```

---

## 13. Glossary

| Term | Meaning |
|---|---|
| **DaemonSet** | A Kubernetes object that runs one pod on every node. |
| **Fluent Bit** | Lightweight log collector/forwarder. |
| **Splunk Enterprise** | Software that stores, indexes and searches log data. |
| **HEC** | HTTP Event Collector: Splunk's HTTPS endpoint (port 8088) for receiving events, protected by a token. |
| **Index** | A named storage bucket in Splunk (here `k8s_logs`) with its own retention and size limit. |
| **Sourcetype** | A label telling Splunk how to parse an event (here `kube:container`). |
| **SPL** | Splunk's search language (the text you type in the search bar). |
| **containerd / CRI** | The container runtime on EKS nodes and the log format it writes. |
| **EBS / gp3** | AWS block storage / its current general-purpose SSD type. |
| **Security group** | AWS's per-instance firewall. |
| **IMDSv2** | The more secure way an EC2 instance reads its own metadata. |

---

## Sources

- [System requirements for use of Splunk Enterprise on-premises (9.4)](https://help.splunk.com/en/splunk-enterprise/administer/install-and-upgrade/9.4/plan-your-splunk-enterprise-installation/system-requirements-for-use-of-splunk-enterprise-on-premises) — supported Ubuntu versions, filesystems, ulimits
- [About Splunk Free (9.4)](https://help.splunk.com/en/splunk-enterprise/administer/admin-manual/9.4/configure-splunk-licenses/about-splunk-free) — 500 MB/day limit, no authentication, 60-day trial
- [Fluent Bit: Splunk output plugin](https://docs.fluentbit.io/manual/data-pipeline/outputs/splunk) — HEC parameters (`splunk_token`, `event_index`, `event_sourcetype`, `tls.verify`, …)
