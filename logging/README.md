# Assignment Portal — Fluent Bit + Splunk Logging on EKS (Step-by-Step Guide)

Send the logs of your **running Assignment Portal** (`frontend`, `backend`, `postgres`, `redis`) from
**`my-eks-cluster`** to a dedicated **Splunk** server, and search them there.

Follow the steps **in order, 1 → 22**. Don't skip ahead. Every step says **where** to run it and **what you should see**.

> Companion file: **[`SPLUNK_QUERIES.md`](SPLUNK_QUERIES.md)** — 200+ ready-to-paste Splunk searches for this application.

---

## What is different from the old sample-logger version

| Before (v4) | Now (v5, this guide) |
|---|---|
| Sample `log-generator` app in `logging-test` namespace | **Removed completely** (no `test/` folder, no test steps) |
| Collected every namespace in the cluster | Collects **only the `assignment-portal` namespace** (your real app) |
| Dropped `kube-probe` / `ELB-HealthChecker` lines only | Also drops `GET /health` (backend probe) and `GET /metrics` (Prometheus scrape every 30 s) |
| Splunk server: 100 GB root disk, Elastic IP | **15 GB root + 60 GB data disk**, plain **public IPv4** (no Elastic IP), **existing `.pem` key** |
| Fields like `kubernetes.labels.app` | Same, **plus short names**: `app`, `namespace`, `pod`, `container`, `image` |
| Verification with fake logs | Verification with **your real portal traffic** |

---

## The big picture (read once, 2 minutes)

```
 YOUR EKS CLUSTER  (my-eks-cluster, 3 x t3.large)            YOUR SPLUNK SERVER (different VPC)
┌──────────────────────────────────────────┐              ┌──────────────────────────────────┐
│ namespace: assignment-portal             │              │ EC2 t3.large                     │
│   frontend x2   (Nginx)                  │              │  root 15 GB  + data disk 60 GB   │
│   backend  x2-5 (Flask/Gunicorn)         │  HTTPS+token │  └─ Splunk (Docker)              │
│   postgres x1                            │ ── 8088 ───► │      ├─ HEC  :8088  (log intake) │
│   redis    x1                            │ (internet,   │      └─ Web  :8000  (you)        │
│ namespace: logging                       │  public IPv4)│                                  │
│   Fluent Bit  (1 pod on every node) ─────┼──────────────┘                                  │
│     reads the log files, adds pod labels │                                                 │
└──────────────────────────────────────────┘              └──────────────────────────────────┘
```

- **Fluent Bit** runs once on every node (a *DaemonSet*), reads the log files of your app's pods, adds labels
  (which pod, which app, which node) and sends the lines to Splunk. Because it works per node, **new pods created by
  the HPA or by an ArgoCD rollout are picked up automatically**.
- **Splunk** stores the logs and lets you search them. Fluent Bit talks to Splunk's **HEC** (an HTTPS intake on port
  8088) using a secret **token**.
- Your Splunk server is in **another VPC**, so logs travel over the **internet** to its **public IPv4**. Port 8088 is
  opened **only to your cluster's worker nodes**, traffic is TLS-encrypted and protected by the token. No VPC peering needed.
- The public IPv4 is **not** an Elastic IP: it changes if you **stop/start** the server. Fine for a demo; the fix takes
  1 minute (see *"If the Splunk public IP changes"* in *Good to know*).
- Fluent Bit's **own logs are never sent** (it only reads the `assignment-portal` namespace).

### The order of work

| Part | Steps | What you do | Where |
|---|---|---|---|
| A | 1–2 | Check tools, connect to the cluster, confirm the app is running | your workstation |
| B | 3–8 | Create the Splunk server on AWS (existing `.pem` key) | workstation → Splunk server |
| C | 9–12 | Install Splunk (Docker) and test it | Splunk server |
| D | 13–15 | Let your cluster reach Splunk on port 8088, and test it | workstation |
| E | 16–19 | Deploy Fluent Bit to the cluster | workstation (`kubectl`) |
| F | 20–22 | Verify with your real app's traffic | workstation + Splunk Web |

**Where to run commands.** Each step is tagged:
**[WORKSTATION]** = the machine where `aws` and `kubectl` work. **[SPLUNK SERVER]** = after `ssh` into the Splunk EC2 box.
**[BROWSER]** = Splunk Web.

**Time:** about 60–90 minutes.
**Assumptions:** AWS region `us-east-1`; EKS cluster `my-eks-cluster` with 3 × `t3.large` nodes (30 GB); your app is
already running in namespace `assignment-portal`; Splunk server = `t3.large`, **15 GB root + 60 GB data disk**, in its own VPC.

---

# PART A — Prepare your workstation

## Step 1 — Check your tools **[WORKSTATION]**

```bash
aws --version
kubectl version --client
ssh -V
aws sts get-caller-identity
```

**Expected:** each command prints a version, and the last one prints your AWS account number.
Missing a tool? Install it (Linux x86_64):

```bash
# AWS CLI
curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && unzip -q awscliv2.zip && sudo ./aws/install
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install -m 0755 kubectl /usr/local/bin/kubectl
# ssh + unzip
sudo apt-get update && sudo apt-get install -y openssh-client unzip curl
```

Then run `aws configure` if `aws sts get-caller-identity` failed.

## Step 2 — Connect `kubectl` and confirm your app is running **[WORKSTATION]**

```bash
aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster
kubectl get nodes
kubectl get pods -n assignment-portal
```

**Expected:** 3 nodes with `STATUS Ready`, then your application pods all `Running` (names and counts will differ a little,
the HPA changes the number of `backend`/`frontend` pods):

```text
NAME                        READY   STATUS    RESTARTS   AGE
backend-xxxxxxxxxx-aaaaa    1/1     Running   0          3d
backend-xxxxxxxxxx-bbbbb    1/1     Running   0          3d
backend-xxxxxxxxxx-ccccc    1/1     Running   0          3d
frontend-xxxxxxxxxx-aaaaa   1/1     Running   0          3d
frontend-xxxxxxxxxx-bbbbb   1/1     Running   0          3d
postgres-xxxxxxxxxx-aaaaa   1/1     Running   0          3d
redis-xxxxxxxxxx-aaaaa      1/1     Running   0          3d
```

If something is not `Running`, fix the app first (see your `pre_installation/01.DeploymentSetUp.md`).

Now copy this `logging/` folder into the **root of your `assignment-portal-k8s` repo**, next to `manifest_files/`:

```text
logging/
├── README.md                          ← this file
├── SPLUNK_QUERIES.md                  ← Splunk searches for your app
├── fluent-bit/
│   ├── 00-namespace.yaml
│   ├── 01-rbac.yaml
│   ├── 02-configmap.yaml              ← the pipeline (reads only assignment-portal)
│   └── 03-daemonset.yaml
└── splunk-server/
    └── bootstrap-splunk-docker.sh
```

> It lives **outside** `manifest_files/` on purpose: your ArgoCD app syncs that folder with `prune: true`, and these
> files are applied by hand. ArgoCD never touches the `logging` namespace, so there is no conflict.
> All commands below are run from the **root of the repo** (the folder that contains `logging/`).

---

# PART B — Create the Splunk server on AWS

> **Already created the server?** If your `t3.large` already exists (Ubuntu 22.04/24.04, 15 GB root + 60 GB extra disk,
> public IPv4, ports 22 and 8000 open to your IP), skip to **Step 8** and just set
> `export INSTANCE_ID=i-…`, `export KEY_NAME=…`, `export PEM_FILE=…` first.

## Step 3 — Pick the Splunk VPC and subnet **[WORKSTATION]**

```bash
export AWS_REGION=us-east-1
aws ec2 describe-vpcs --region $AWS_REGION \
  --query 'Vpcs[].{VPC:VpcId,CIDR:CidrBlock,Default:IsDefault,Name:Tags[?Key==`Name`]|[0].Value}' --output table
```

Choose **the VPC where your Splunk server lives (or will live)** — *not* the EKS VPC. Then:

```bash
export SPLUNK_VPC_ID=vpc-xxxxxxxxxxxxxxxxx        # <-- paste YOUR Splunk VPC id

# a PUBLIC subnet in that VPC, and your own public IP (so only you can reach SSH and Splunk Web)
export SPLUNK_SUBNET_ID=$(aws ec2 describe-subnets --region $AWS_REGION \
  --filters Name=vpc-id,Values=$SPLUNK_VPC_ID Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[0].SubnetId' --output text)
export MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "VPC=$SPLUNK_VPC_ID  SUBNET=$SPLUNK_SUBNET_ID  MY_IP=$MY_IP"
```

**Expected:** the subnet shows `subnet-…`. If it shows `None`, pick a subnet whose route table has an Internet Gateway
in the AWS console and set `SPLUNK_SUBNET_ID` by hand. (The server needs internet access to download Docker and Splunk.)

## Step 4 — Create the firewall (security group) **[WORKSTATION]**

```bash
export SG_ID=$(aws ec2 create-security-group --region $AWS_REGION \
  --group-name splunk-server-sg --description "Splunk server" --vpc-id $SPLUNK_VPC_ID \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SG_ID --protocol tcp --port 22   --cidr ${MY_IP}/32
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SG_ID --protocol tcp --port 8000 --cidr ${MY_IP}/32
echo "Security group: $SG_ID"
```

**Expected:** a `sg-…` id, and two results containing `"Return": true`.
This opens SSH (22) and Splunk Web (8000) **to your IP only**. The log-intake port 8088 is opened later (Step 14),
only to your cluster's nodes.

## Step 5 — Use your existing SSH key (`.pem`) **[WORKSTATION]**

You already have a key pair, so nothing new is created. Tell the commands which one to use:

```bash
export KEY_NAME=<your-existing-key-pair-name>        # the name shown in EC2 -> Key Pairs (no .pem)
export PEM_FILE=<full-path-to-your-key>.pem           # e.g. ~/keys/my-key.pem

aws ec2 describe-key-pairs --region $AWS_REGION --key-names $KEY_NAME --query 'KeyPairs[0].KeyName' --output text
chmod 400 $PEM_FILE
ls -l $PEM_FILE
```

**Expected:** the key name is printed back, and `ls -l` shows `-r--------`.
If you get `InvalidKeyPair.NotFound`, the key pair lives in another region — check `AWS_REGION`.

## Step 6 — Launch the `t3.large` (15 GB root + 60 GB data disk) **[WORKSTATION]**

```bash
export AMI_ID=$(aws ssm get-parameter --region $AWS_REGION \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)

export INSTANCE_ID=$(aws ec2 run-instances --region $AWS_REGION \
  --image-id $AMI_ID --instance-type t3.large --key-name $KEY_NAME \
  --subnet-id $SPLUNK_SUBNET_ID --security-group-ids $SG_ID --associate-public-ip-address \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":15,"VolumeType":"gp3","DeleteOnTermination":true}},{"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":60,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=splunk-server}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --region $AWS_REGION --instance-ids $INSTANCE_ID
echo "Instance: $INSTANCE_ID"
```

**Expected:** an `i-…` id after about 30–60 seconds.

- `/dev/sda1` = the **15 GB root disk** (Ubuntu + Docker program files only).
- `/dev/sdf` = the **60 GB data disk**. The install script (Step 10) formats it and puts **Splunk and all your logs on it**.
- `--associate-public-ip-address` gives the server a normal **public IPv4**.
- `t3.large` = 2 vCPU / 8 GB RAM: fine for a demo with this app's log volume.

> **Prefer the AWS console?** EC2 → Launch instance → Ubuntu Server 24.04 → `t3.large` → your existing key pair →
> your Splunk VPC + public subnet, *Auto-assign public IP = Enable* → security group from Step 4 → Storage: root **15 GiB gp3**,
> then **Add new volume** **60 GiB gp3** (`/dev/sdf`). Then run `export INSTANCE_ID=i-…` here.

## Step 7 — Get the server's public IPv4 **[WORKSTATION]**

```bash
export SPLUNK_PUBLIC_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Splunk public IP: $SPLUNK_PUBLIC_IP"
```

**Expected:** an address such as `3.91.xx.xx`. **Write it down.** It is the address for your browser, for SSH and for Fluent Bit.
(It stays the same across reboots, but changes if you *stop* and later *start* the server.)

## Step 8 — Log in to the server **[WORKSTATION → SPLUNK SERVER]**

Wait about 1 minute for the server to finish booting, then:

```bash
ssh -i $PEM_FILE ubuntu@$SPLUNK_PUBLIC_IP
lsblk
```

**Expected:** an Ubuntu welcome message and a prompt `ubuntu@ip-…:~$`. `lsblk` shows two disks, similar to:

```text
NAME         MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme0n1      259:0    0   15G  0 disk
├─nvme0n1p1  259:1    0   14G  0 part /
├─nvme0n1p14 259:2    0    4M  0 part
├─nvme0n1p15 259:3    0  106M  0 part /boot/efi
└─nvme0n1p16 259:4    0  913M  0 part /boot
nvme1n1      259:5    0   60G  0 disk                <-- the empty 60 GB data disk
```

(If SSH times out: your IP changed or the subnet isn't public. Re-check Steps 3–4. If it says `Permission denied (publickey)`,
you are using the wrong `.pem` for that key pair.)

Leave this SSH window open. You'll use it in Part C.

---

# PART C — Install Splunk (Docker image)

## Step 9 — Copy the install script to the server **[WORKSTATION]**

Open a **second terminal** on your workstation (keep the SSH one), go to the repo root, and:

```bash
scp -i $PEM_FILE logging/splunk-server/bootstrap-splunk-docker.sh ubuntu@$SPLUNK_PUBLIC_IP:~/
```

(If this is a new terminal, `$PEM_FILE` and `$SPLUNK_PUBLIC_IP` are empty. Type the real path and the IP from Step 7 instead.)

**Expected:** `bootstrap-splunk-docker.sh   100%  …`

## Step 10 — Run the install script **[SPLUNK SERVER]**

In the SSH window. Choose your own Splunk admin password:

```bash
export SPLUNK_ADMIN_PASSWORD='Choose-A-Strong-Pass1'
sudo -E bash bootstrap-splunk-docker.sh
```

- Password rules: **8+ characters, only letters, digits and `. _ ! @ % + = -`**.
- The script sets `SPLUNK_GENERAL_TERMS`, which means **you accept the Splunk General Terms** (the Splunk 10.x image requires this). Read them on splunk.com first.
- Takes **5–10 minutes**. The first start is slow because the Splunk image configures itself.

What the script does: finds the empty **60 GB disk**, formats it and mounts it at `/var/lib/docker` → installs Docker →
writes `/opt/splunk-stack/` (container definition + settings) → starts Splunk → creates the `k8s_logs` index, turns on
the HEC intake, creates a token, adds the short field names (`app`, `pod`, …) → waits until everything is healthy.
The index is capped at 60 % of the data disk (about **34 GB**) and logs older than **30 days** are deleted automatically.

**Expected, near the start:**

```text
[..] 1/5 Preparing data disk /dev/nvme1n1
[..]     No filesystem found - formatting /dev/nvme1n1 as ext4
[..]     Index size cap: 34 GB, kept 30 days
```

**Expected last lines:**

```text
=============================================================================
 Splunk (Docker) is ready.

 Web UI      : http://<this-server-public-IP>:8000     user: admin
 HEC health  : OK (https://<public-ip>:8088)
 Index       : k8s_logs  -> created
 Image       : splunk/splunk:latest

 Values for Fluent Bit (also saved in /root/splunk-hec-info.txt, root-only):
     SPLUNK_HOST=<public-ip>
     SPLUNK_PORT=8088
     SPLUNK_HEC_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
=============================================================================
```

**Copy the three `SPLUNK_…` lines into a notepad.** You need them in Step 17. `SPLUNK_HOST` must equal the public IP from
Step 7 (if it shows a `10.x`, `172.x` or `192.168.x` address, use the public IP from Step 7 instead).
(Lost them? Run `sudo cat /root/splunk-hec-info.txt` on the server.)

Check that the data disk is really used (should show about 58–59 GB, not 15 GB):

```bash
df -h /var/lib/docker
```

If the `Index` line says **NOT FOUND**: in Splunk Web (next step) go to **Settings → Indexes → New Index**, name it
`k8s_logs`, Save. Everything else keeps working.

## Step 11 — Open Splunk Web **[BROWSER]**

Go to `http://<SPLUNK_PUBLIC_IP>:8000` and sign in as **admin** with your password. Click through any first-run pop-ups.

**Expected:** the Splunk home page. Under **Settings → Licensing** you'll see a trial license and its daily limit.

## Step 12 — Test that Splunk accepts logs **[SPLUNK SERVER]**

This proves Splunk works *before* Kubernetes is involved:

```bash
source <(sudo sed 's/^/export /' /root/splunk-hec-info.txt)
curl -k https://127.0.0.1:8088/services/collector/event \
  -H "Authorization: Splunk $SPLUNK_HEC_TOKEN" \
  -d '{"event":"hello from curl","sourcetype":"manual","index":"k8s_logs"}'
```

**Expected:** `{"text":"Success","code":0}`

Then in **[BROWSER]** → **Search & Reporting**, set the time range to *Last 15 minutes* and search:

```spl
index=k8s_logs "hello from curl"
```

**Expected:** 1 event. Splunk is ready. You can leave the SSH window now (`exit`).

---

# PART D — Let your cluster reach Splunk (port 8088)

Splunk is on the internet through its public IPv4, but port 8088 (log intake) is still **closed to everyone**. We now open it
**only to your cluster's worker nodes**.

## Step 13 — Find the Splunk server details **[WORKSTATION]**

Works in a new terminal too:

```bash
export AWS_REGION=us-east-1
export INSTANCE_ID=$(aws ec2 describe-instances --region $AWS_REGION \
  --filters Name=tag:Name,Values=splunk-server Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
export SG_ID=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
export SPLUNK_PUBLIC_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Instance: $INSTANCE_ID   Firewall: $SG_ID   Splunk IP: $SPLUNK_PUBLIC_IP"
```

**Expected:** an `i-…` id, an `sg-…` id, and the public IP from Step 7.

## Step 14 — Open port 8088 to your worker nodes only **[WORKSTATION]**

Traffic from your cluster reaches the internet with its nodes' public IPs, so we allow exactly those:

```bash
NODE_IPS=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{"\n"}{end}')
echo "$NODE_IPS"

for ip in $NODE_IPS; do
  aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SG_ID \
    --protocol tcp --port 8088 --cidr $ip/32
done
```

**Expected:** 3 IP addresses printed (one per node), then three results that include `"Return": true`.

Now double-check that the cluster really leaves the internet with one of those IPs:

```bash
kubectl run ip-check --rm -it --restart=Never --image=curlimages/curl -- curl -s https://checkip.amazonaws.com
```

**Expected:** an IP that is **one of the three** printed above (then `pod "ip-check" deleted`).
If it is a different IP (or `NODE_IPS` was empty because your nodes are in private subnets), that address is your NAT
gateway's. Allow it instead:

```bash
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SG_ID --protocol tcp --port 8088 --cidr <that-ip>/32
```

> **Remember:** if a node is replaced or you add nodes, its public IP changes. Re-run the `for` loop above
> (a "Duplicate" error for IPs already allowed is harmless).
> *Demo-only shortcut:* allowing `0.0.0.0/0` on port 8088 avoids this chore, and the token plus TLS still protect it,
> but it exposes the port to the whole internet. Don't keep that for anything long-lived.

## Step 15 — Test the connection from inside the cluster **[WORKSTATION]**

This starts a throw-away pod in the cluster and asks Splunk if it is healthy:

```bash
kubectl run net-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sk --max-time 10 https://$SPLUNK_PUBLIC_IP:8088/services/collector/health
```

**Expected:** `{"text":"HEC is healthy","code":17}` (then `pod "net-test" deleted`).

**Do not continue until you see this.** If it hangs or times out, see **Troubleshooting → "Step 15 fails"** at the bottom.

---

# PART E — Deploy Fluent Bit to the cluster

## Step 16 — Create the `logging` namespace **[WORKSTATION]**

```bash
kubectl apply -f logging/fluent-bit/00-namespace.yaml
```

**Expected:** `namespace/logging created`.

## Step 17 — Create the Splunk secret **[WORKSTATION]**

Use the three values from Step 10. `SPLUNK_HOST` is the server's **public IPv4**:

```bash
kubectl create secret generic splunk-hec -n logging \
  --from-literal=SPLUNK_HOST='<splunk-public-ip>' \
  --from-literal=SPLUNK_PORT='8088' \
  --from-literal=SPLUNK_HEC_TOKEN='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Expected:** `secret/splunk-hec created`.
The token is a password. Creating it with a command (not a YAML file) keeps it **out of Git**.

## Step 18 — Deploy Fluent Bit **[WORKSTATION]**

```bash
kubectl apply -f logging/fluent-bit/01-rbac.yaml
kubectl apply -f logging/fluent-bit/02-configmap.yaml
kubectl apply -f logging/fluent-bit/03-daemonset.yaml
```

**Expected:** `serviceaccount/fluent-bit created`, `clusterrole…`, `clusterrolebinding…`, `configmap/fluent-bit-config created`,
`daemonset.apps/fluent-bit created`.

## Step 19 — Check Fluent Bit is running **[WORKSTATION]**

```bash
kubectl get ds -n logging
kubectl get pods -n logging -o wide
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=20
```

**Expected:**

```text
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
fluent-bit   3         3         3       3            3
```

3 pods `Running`, one per node, and the logs show **few or no lines** (it only prints warnings and errors).
A line with `[error]` means a problem, so see **Troubleshooting**. These messages stay in your terminal on purpose;
they are not sent to Splunk.

---

# PART F — Verify with your real application

No fake app is needed: your portal is already running. We just make it print a few log lines on purpose.

## Step 20 — Generate some real traffic **[WORKSTATION]**

Find your portal's address (the ALB created by your Ingress):

```bash
export ALB_URL=$(kubectl get ingress assignment-portal-ingress -n assignment-portal \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $ALB_URL
```

**Expected:** something like `k8s-assignme-assignme-xxxxxxxxxx-123456789.us-east-1.elb.amazonaws.com`.

Send a few requests (this prints the HTTP status code of each; exact codes depend on your app, `200` / `302` are normal):

```bash
for i in 1 2 3 4 5; do curl -s -o /dev/null -w "home:  %{http_code}\n"  http://$ALB_URL/; done
for i in 1 2 3;     do curl -s -o /dev/null -w "login: %{http_code}\n"  http://$ALB_URL/login; done
curl -s -o /dev/null -w "missing page: %{http_code}\n" http://$ALB_URL/this-page-does-not-exist
```

Also open `http://<ALB_URL>` **in your browser**, sign in and click around (view assignments, submit something, sign out).
That creates real backend, Postgres and Redis activity.

Now look at what the pods themselves printed (this is the "truth" to compare Splunk with):

```bash
kubectl logs -n assignment-portal deploy/frontend --tail=5
kubectl logs -n assignment-portal deploy/backend  --tail=5
```

Wait **1–2 minutes**.

## Step 21 — Check the results in Splunk **[BROWSER]**

Open **Search & Reporting**, set the time range to **Last 60 minutes**, and run each search.
(Fluent Bit starts from the beginning of the files, so you may also see some older lines. That is normal.)

| # | Check | Search | Expected |
|---|---|---|---|
| 1 | All 4 components arrive | `index=k8s_logs \| stats count by app` | rows `backend`, `frontend`, `postgres`, `redis` (redis/postgres counts are small, that's fine) |
| 2 | Only your namespace | `index=k8s_logs \| stats count by namespace` | **one row**: `assignment-portal` |
| 3 | Every pod reports | `index=k8s_logs \| stats count by app, pod` | one row per pod: 2–5 `backend`, 2–5 `frontend`, 1 `postgres`, 1 `redis` |
| 4 | **Probe/ALB health checks dropped** | `index=k8s_logs ("kube-probe" OR "ELB-HealthChecker")` | **0 events** |
| 5 | **`/health` and `/metrics` dropped** | `index=k8s_logs ("GET /health" OR "GET /metrics")` | **0 events** |
| 6 | Your real requests are there | `index=k8s_logs app=frontend "this-page-does-not-exist"` | 1+ events with status `404` |
| 7 | Portal pages visible | `index=k8s_logs app=frontend "GET /login"` | the lines from your `curl` / browser |
| 8 | Cluster tag present | `index=k8s_logs \| stats count by cluster` | `my-eks-cluster` |
| 9 | **Fluent Bit's own logs excluded** | `index=k8s_logs namespace=logging` | **0 events** |

For checks 4 and 5, the pods *do* print those lines (prove it with `kubectl logs -n assignment-portal deploy/backend --tail=20 | grep -i health`);
Fluent Bit just doesn't send them. That is the point.

**All 9 as expected? Your pipeline works.** Open **[`SPLUNK_QUERIES.md`](SPLUNK_QUERIES.md)** for 200+ searches, alerts and dashboard ideas.

If a check fails, widen the time range to *Last 24 hours*, then see **Troubleshooting**.
If `app` / `namespace` / `pod` show nothing, use the long names instead
(`kubernetes.labels.app`, `kubernetes.namespace_name`, `kubernetes.pod_name`) — see **Troubleshooting**.

> **Is the Nginx log format without a User-Agent?** If check 4 shows events, or you see `GET / HTTP/1.1` lines every
> few seconds from each frontend pod, your Nginx access log doesn't contain the User-Agent. Ask for help adding an
> extra `Exclude` for that format, or switch the frontend to the default `combined` log format.

## Step 22 — (Optional) Prove nothing is lost when Splunk is down **[SPLUNK SERVER]**

```bash
ssh -i $PEM_FILE ubuntu@$SPLUNK_PUBLIC_IP
cd /opt/splunk-stack && sudo docker compose stop
```

Wait **3 minutes**. In another terminal keep the portal busy (it generates log lines):

```bash
for i in $(seq 1 60); do curl -s -o /dev/null http://$ALB_URL/login; sleep 3; done
```

Then on the server `sudo docker compose start`. Splunk needs a few minutes to be healthy again (`sudo docker compose ps`). Then search:

```spl
index=k8s_logs app=frontend "GET /login"
| timechart span=1m count
```

**Expected:** no gap in the chart. Fluent Bit held the logs on the node's disk (up to 500 MB per node) and delivered them when Splunk came back.

---

# Good to know

**Everyday Splunk commands** (on the Splunk server):

```bash
cd /opt/splunk-stack
sudo docker compose ps          # is it running?
sudo docker compose logs -f     # follow output (Ctrl+C to stop)
sudo docker compose restart     # restart
sudo docker compose stop        # stop (data is kept)   |   sudo docker compose up -d   # start
```

Your logs live in Docker volumes on the **60 GB data disk**, so recreating the container keeps them (`docker compose down -v` deletes them).
**Pin the Splunk version** once it works: `sudo docker exec splunk /opt/splunk/bin/splunk version`, then put
`SPLUNK_IMAGE=splunk/splunk:<that-version>` in `/opt/splunk-stack/.env` and run `sudo docker compose up -d`.

### If the Splunk public IP changes (after you stop/start the server)

The server's address is only used in three places. Update them:

```bash
# 1. get the new IP
export SPLUNK_PUBLIC_IP=$(aws ec2 describe-instances --region us-east-1 --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text); echo $SPLUNK_PUBLIC_IP

# 2. point Fluent Bit at it (token stays the same: sudo cat /root/splunk-hec-info.txt on the server)
kubectl delete secret splunk-hec -n logging
kubectl create secret generic splunk-hec -n logging \
  --from-literal=SPLUNK_HOST="$SPLUNK_PUBLIC_IP" --from-literal=SPLUNK_PORT='8088' \
  --from-literal=SPLUNK_HEC_TOKEN='<your-token>'
kubectl rollout restart ds/fluent-bit -n logging
```

3. Use the new IP in your browser and SSH. The firewall rules for 22/8000 depend on **your** IP, and the 8088 rules on the
**node** IPs, so those do not change. While Fluent Bit cannot reach Splunk it keeps the logs on the node's disk and sends them afterwards.

**Change what Fluent Bit collects.** Edit `logging/fluent-bit/02-configmap.yaml`, then:

```bash
kubectl apply -f logging/fluent-bit/02-configmap.yaml
kubectl rollout restart ds/fluent-bit -n logging
```

| I want to… | Change |
|---|---|
| Also collect ArgoCD or monitoring (Prometheus/Grafana) logs | In `[INPUT]`, add namespaces to `Path`, comma separated: `/var/log/containers/*_assignment-portal_*.log,/var/log/containers/*_argocd_*.log` |
| Collect the whole cluster again | `Path  /var/log/containers/*.log` **and** add `Exclude_Path  /var/log/containers/*_logging_*.log` (so Fluent Bit doesn't read its own logs) |
| Keep `/metrics` or `/health` lines | Delete the 2nd `[FILTER]` (grep) block |
| Drop all stderr (careful: Flask/Gunicorn log there) | Uncomment the `Exclude  stream stderr` block |
| Merge Python tracebacks into one event | Uncomment the `multiline` filter block (4 lines) |
| Exclude one Deployment | Add the annotation `fluentbit.io/exclude: "true"` to its **pod template** (in Git, so ArgoCD keeps it) |

**License / volume.** Trial license = 60 days. Check the daily cap at **Settings → Licensing** (Splunk Free is limited to 500 MB/day and has no login). See your real volume with:

```spl
index=_internal source=*license_usage.log* type=Usage | eval GB=b/1024/1024/1024 | timechart span=1d sum(GB)
```

**Disk layout.** Root disk (15 GB) = Ubuntu + Docker program. Data disk (60 GB) = Splunk image and all logs, capped at about 34 GB
with 30-day retention, so the disk can't fill up. Check any time: `df -h / /var/lib/docker`.

**Passwords in logs.** Your Deployment sets `DATABASE_URL` with the Postgres password in plain text. If the backend ever prints its
environment or a connection string, the password would be stored in Splunk. `SPLUNK_QUERIES.md` has a search to check for this.

**Why these choices?**

- **Only the `assignment-portal` namespace:** keeps Splunk small and focused, and keeps Fluent Bit from ever reading its own logs.
- **Resource requests/limits** (`50m`/`64Mi` request, `200m`/`200Mi` limit): without requests the pod is the first one evicted when a node is short on memory (and then that node's logs stop); the memory limit protects your app pods.
- **No EBS volume for Fluent Bit:** it keeps a small state folder (read positions plus a disk buffer, max 500 MB) on the **node's own disk (30 GB, already EBS)**. A DaemonSet can't give each pod its own volume claim, and the files must be local to the node anyway.
- **RBAC** (`01-rbac.yaml`): Fluent Bit asks the Kubernetes API "which pod/namespace/labels does this log file belong to?". Without read access to pods and namespaces, every event loses its labels. The permission is read-only on pods and namespaces, nothing else.
- **Pod limit:** a `t3.large` node allows max **35 pods**. Fluent Bit adds one per node. Check with `kubectl get pods -A --no-headers -o custom-columns=NODE:.spec.nodeName | sort | uniq -c`.
- **ArgoCD:** `prune` and `selfHeal` only apply to `assignment-portal`. The `logging` namespace is yours, so nothing here is reverted.

**Hardening before real production use.** (1) HEC uses Splunk's self-signed certificate, so the config has `TLS.Verify Off`; traffic is encrypted, but the server's identity isn't checked. Install a real certificate (with a DNS name) and set `TLS.Verify On` later. (2) Use an Elastic IP or a DNS name for Splunk. (3) Put Splunk Web behind HTTPS and a VPN, and use AWS Systems Manager instead of SSH. (4) Move the token to AWS Secrets Manager. (5) Snapshot the Splunk data disk regularly. (6) Pin image versions (Fluent Bit is `5.1.4`).

---

# Troubleshooting

First look at Fluent Bit's messages:

```bash
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=50
```

| Problem | Likely cause → fix |
|---|---|
| **Step 15 fails** (hangs / timeout) | In order: (1) the firewall allows your nodes: run the `ip-check` pod from Step 14 and compare its IP with `aws ec2 describe-security-groups --region $AWS_REGION --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==\`8088\`].IpRanges[].CidrIp'`; (2) Splunk is running (`sudo docker compose ps` on the server); (3) `SPLUNK_PUBLIC_IP` is the **current** IP (it changes after stop/start, re-run Step 13); (4) the instance is in a **public** subnet with an Internet Gateway route |
| Pod `CreateContainerConfigError` | The secret is missing → redo Step 17 (`kubectl get secret -n logging`) |
| Pod `ImagePullBackOff` on `fluent/fluent-bit:5.1.4` | That tag wasn't found. Edit `03-daemonset.yaml` to `fluent/fluent-bit:5.1.2` and re-apply |
| Pod `Pending`, "Too many pods" | A node is full (35 pods on `t3.large`). Free a slot or add a node |
| Pod `CrashLoopBackOff`, `[error] [config]` | Typo/indentation in the ConfigMap; fix it, re-apply, `rollout restart` |
| `[error] … broken connection` / `timed out` | Same as Step 15. Also common: a node was replaced and its new IP is not allowed yet → re-run the loop in Step 14 |
| `HTTP status=403` / invalid token | Wrong token. Compare with `sudo cat /root/splunk-hec-info.txt`, recreate the secret (below) |
| `HTTP status=400` / "Incorrect index" | Index `k8s_logs` doesn't exist → Splunk Web: Settings → Indexes → New Index |
| Pods run but **no data** in Splunk | Wait 2 minutes; search `index=k8s_logs earliest=-24h`; check counters: `kubectl port-forward -n logging ds/fluent-bit 2020:2020 &` then `curl -s localhost:2020/api/v1/metrics` (rising `proc_records` and `errors` = 0 is healthy; rising `retries` = Splunk unreachable); then `kill %1` |
| Data arrives but **`app`, `pod`, `namespace` are empty** | Short names exist only if the install script of this guide created them. Use the long names: `kubernetes.labels.app`, `kubernetes.pod_name`, `kubernetes.namespace_name`, `kubernetes.container_name`, `kubernetes.container_image`. Or add them in Splunk Web: Settings → Fields → Field aliases → New, sourcetype `kube:container` |
| Only some components appear (e.g. no `postgres`) | That pod printed nothing yet (Postgres/Redis are quiet when idle). Restart one: `kubectl rollout restart deploy/redis -n assignment-portal` and search again |
| Check 4 shows `kube-probe` events | Fluent Bit config not applied or not restarted: `kubectl rollout restart ds/fluent-bit -n logging` (already-indexed lines stay; search only the last 15 minutes) |
| Splunk script says "did not become healthy" | Normal on slow first start. Run `sudo docker logs -f splunk` and read the last lines; re-run the script (it resumes safely) |
| Script says "`/var/lib/docker` already has data" | Docker was installed before the data disk was set up. Use a fresh instance, or move that folder yourself first |
| Splunk Web unreachable | Your IP changed → re-add it to the security group for ports 22 and 8000 (Step 4 commands) |
| Splunk stopped after reboot | `cd /opt/splunk-stack && sudo docker compose up -d` |
| Admin password forgotten | `sudo docker exec splunk /opt/splunk/bin/splunk edit user admin -password 'NewPass123' -auth admin:OldPass` |
| Disk filling up | Lower the retention/size of `k8s_logs` in Splunk Web (Settings → Indexes), or grow the 60 GB EBS volume and run `sudo resize2fs /dev/<data-disk>` |

Changing the secret (new token or IP) needs a restart, since environment variables are read at start:

```bash
kubectl delete secret splunk-hec -n logging
kubectl create secret generic splunk-hec -n logging --from-literal=SPLUNK_HOST='…' --from-literal=SPLUNK_PORT='8088' --from-literal=SPLUNK_HEC_TOKEN='…'
kubectl rollout restart ds/fluent-bit -n logging
```

---

# Clean up (when you no longer need it)

**Cluster side:**

```bash
kubectl delete -f logging/fluent-bit/03-daemonset.yaml -f logging/fluent-bit/02-configmap.yaml -f logging/fluent-bit/01-rbac.yaml
kubectl delete secret splunk-hec -n logging
kubectl delete -f logging/fluent-bit/00-namespace.yaml
```

**AWS side (this deletes all stored logs, both disks are deleted with the server):**

```bash
aws ec2 terminate-instances --region $AWS_REGION --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --region $AWS_REGION --instance-ids $INSTANCE_ID
aws ec2 delete-security-group --region $AWS_REGION --group-id $SG_ID
```

> **Do NOT delete your key pair.** It was already yours and may be used by other servers.

---

# Glossary

| Term | Meaning |
|---|---|
| **Fluent Bit** | The small program that reads log files and forwards them. |
| **DaemonSet** | A Kubernetes object that runs exactly one pod on every node. |
| **Splunk** | The server that stores and searches the logs. |
| **HEC** | HTTP Event Collector: Splunk's intake on port 8088, protected by a token. |
| **Index** | A named storage area in Splunk (`k8s_logs`) with its own retention. |
| **SPL** | Splunk's search language (what you type in the search bar). |
| **Field alias** | A short search-time name for a longer field (`app` = `kubernetes.labels.app`). |
| **Public IPv4** | A public address that is kept while the server runs but can change after stop/start (unlike an Elastic IP). |

---

*Sources: [Splunk docker image](https://github.com/splunk/docker-splunk) · [Fluent Bit Splunk output](https://docs.fluentbit.io/manual/data-pipeline/outputs/splunk) · [Fluent Bit grep filter](https://docs.fluentbit.io/manual/data-pipeline/filters/grep) · [Fluent Bit multiline filter](https://docs.fluentbit.io/manual/data-pipeline/filters/multiline-stacktrace)*
