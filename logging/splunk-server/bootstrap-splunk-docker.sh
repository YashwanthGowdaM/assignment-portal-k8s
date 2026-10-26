#!/usr/bin/env bash
# =============================================================================
# bootstrap-splunk-docker.sh
# Runs Splunk Enterprise as a Docker container (official "splunk/splunk" image)
# on a dedicated Ubuntu EC2 server, ready to receive Kubernetes logs from Fluent Bit.
#
# Run ONCE, as root, on a fresh Ubuntu 22.04 / 24.04 EC2 instance (x86_64):
#
#   export SPLUNK_ADMIN_PASSWORD='<8+ chars: letters, digits and . _ ! @ % + = - only>'
#   sudo -E bash bootstrap-splunk-docker.sh
#
# What it does:
#   1. If a spare (empty) EBS data disk is attached (planned: 15 GB root + 60 GB
#      data disk), formats it and mounts it at /var/lib/docker, so the Splunk image
#      and ALL indexed logs live on the 60 GB disk. If there is no spare disk,
#      everything simply lives on the root disk.
#   2. Installs Docker Engine + the Compose plugin (from Docker's official apt repo)
#   3. Writes /opt/splunk-stack/{docker-compose.yml,default.yml,.env}
#        - default.yml creates the "k8s_logs" index, turns on HEC and sets the token,
#          and adds short search-time field names for the assignment-portal logs:
#            app, namespace, pod, container, image  (see SPLUNK_QUERIES.md)
#   4. Pulls the Splunk image and starts it (auto-restarts after a reboot)
#   5. Waits until Splunk Web and HEC are healthy and prints the Fluent Bit values
#
# Safe to re-run: skips finished steps and reuses the same HEC token.
#
# NOTE: setting SPLUNK_GENERAL_TERMS below means YOU accept the Splunk General
# Terms (required by the 10.x Splunk image). Read them on splunk.com first.
# =============================================================================
set -euo pipefail

# ----------------------------- settings you may change -----------------------
STACK_DIR="/opt/splunk-stack"
DOCKER_ROOT="/var/lib/docker"
SPLUNK_IMAGE="${SPLUNK_IMAGE:-splunk/splunk:latest}"   # pin a version later, e.g. splunk/splunk:10.0.0
INDEX_NAME="${INDEX_NAME:-k8s_logs}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"          # events older than this are deleted
INDEX_MAX_GB="${INDEX_MAX_GB:-}"                # size cap for the index; empty = 60% of the disk (auto)
DATA_DEVICE="${DATA_DEVICE:-}"                  # e.g. /dev/nvme1n1 (auto-detected if empty)
WAIT_SECONDS="${WAIT_SECONDS:-900}"             # first start is slow (Ansible setup inside the image)

# ----------------------------- helpers ---------------------------------------
log() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------- pre-flight checks -----------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo -E bash $0"
: "${SPLUNK_ADMIN_PASSWORD:?Set SPLUNK_ADMIN_PASSWORD first (see top of this script)}"
[[ "${SPLUNK_ADMIN_PASSWORD}" =~ ^[A-Za-z0-9._!@%+=-]{8,}$ ]] \
  || die "Password must be 8+ characters using only letters, digits and . _ ! @ % + = -"
[ "$(uname -m)" = "x86_64" ] || die "This script expects an x86_64 instance (not Graviton/ARM)"
command -v apt-get >/dev/null 2>&1 || die "This script uses apt-get (Ubuntu/Debian). Splunk itself runs in Docker, so any Ubuntu version is fine."

# ----------------------------- 1. data disk ----------------------------------
detect_data_device() {
  # first whole disk that has no partitions and nothing mounted
  lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}' | while read -r d; do
    if [ -z "$(lsblk -nro MOUNTPOINT "$d" | tr -d '[:space:]')" ] \
       && [ "$(lsblk -nro NAME "$d" | wc -l)" -eq 1 ]; then
      echo "$d"; break
    fi
  done
}

if mountpoint -q "${DOCKER_ROOT}"; then
  log "1/5 ${DOCKER_ROOT} is already a mount point - skipping disk setup"
else
  [ -n "${DATA_DEVICE}" ] || DATA_DEVICE="$(detect_data_device)"
  if [ -z "${DATA_DEVICE}" ]; then
    log "1/5 No extra data disk found - Docker and Splunk data will live on the root disk"
  else
    if [ -d "${DOCKER_ROOT}" ] && [ -n "$(ls -A "${DOCKER_ROOT}" 2>/dev/null)" ]; then
      die "${DOCKER_ROOT} already has data on the root disk. Use a fresh instance, or move it yourself first."
    fi
    log "1/5 Preparing data disk ${DATA_DEVICE}"
    if ! blkid "${DATA_DEVICE}" >/dev/null 2>&1; then
      log "    No filesystem found - formatting ${DATA_DEVICE} as ext4"
      mkfs.ext4 -q -L splunkdata "${DATA_DEVICE}"
    else
      log "    Existing filesystem found - keeping it (data is NOT erased)"
    fi
    mkdir -p "${DOCKER_ROOT}"
    UUID="$(blkid -s UUID -o value "${DATA_DEVICE}")"
    grep -q "${UUID}" /etc/fstab || echo "UUID=${UUID} ${DOCKER_ROOT} ext4 defaults,nofail 0 2" >> /etc/fstab
    mount "${DOCKER_ROOT}"
  fi
fi

# Index size cap: 60% of the disk that holds Docker's data, unless you set INDEX_MAX_GB.
# (Splunk stops indexing when free space gets low, so we never let the index fill the disk.)
mkdir -p "${DOCKER_ROOT}"
if [ -z "${INDEX_MAX_GB}" ]; then
  DISK_GB="$(df -BG --output=size "${DOCKER_ROOT}" | tail -1 | tr -dc '0-9')"
  INDEX_MAX_GB=$(( DISK_GB * 60 / 100 ))
  [ "${INDEX_MAX_GB}" -ge 5 ] || INDEX_MAX_GB=5
fi
log "    Index size cap: ${INDEX_MAX_GB} GB, kept ${RETENTION_DAYS} days"

# ----------------------------- 2. Docker -------------------------------------
if docker compose version >/dev/null 2>&1; then
  log "2/5 Docker + Compose already installed - skipping"
else
  log "2/5 Installing Docker and Compose from Ubuntu's own package repository"
  apt-get update -y
  apt-get install -y curl docker.io docker-compose-v2
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 \
    || die "Docker Compose is still missing. Try: sudo apt-get install -y docker-compose-v2   (or docker-compose-plugin)"
fi

# ----------------------------- 3. stack files --------------------------------
log "3/5 Writing ${STACK_DIR} (compose file, Splunk defaults, secrets)"
mkdir -p "${STACK_DIR}"
umask 077

# Reuse the existing HEC token on re-runs, otherwise create one.
if [ -f "${STACK_DIR}/default.yml" ] && grep -qE '^ +token: ' "${STACK_DIR}/default.yml"; then
  HEC_TOKEN="$(awk '/^ +token: /{print $2; exit}' "${STACK_DIR}/default.yml")"
  log "    Re-using existing HEC token"
else
  HEC_TOKEN="$(cat /proc/sys/kernel/random/uuid)"
fi

cat > "${STACK_DIR}/.env" <<EOF
SPLUNK_PASSWORD=${SPLUNK_ADMIN_PASSWORD}
SPLUNK_IMAGE=${SPLUNK_IMAGE}
EOF

cat > "${STACK_DIR}/docker-compose.yml" <<'EOF'
services:
  splunk:
    image: ${SPLUNK_IMAGE}
    container_name: splunk
    hostname: splunk
    restart: unless-stopped            # comes back by itself after a reboot
    environment:
      SPLUNK_START_ARGS: "--accept-license"
      SPLUNK_GENERAL_TERMS: "--accept-sgt-current-at-splunk-com"
      SPLUNK_PASSWORD: ${SPLUNK_PASSWORD}
    ports:
      - "8000:8000"                    # Splunk Web (you)
      - "8088:8088"                    # HEC: log intake (Fluent Bit)
    volumes:
      - splunk-etc:/opt/splunk/etc     # configuration  (persists)
      - splunk-var:/opt/splunk/var     # indexed logs   (persists, lives on the data disk)
      - ./default.yml:/tmp/defaults/default.yml:ro

volumes:
  splunk-etc:
  splunk-var:
EOF

# default.yml = Splunk's first-start settings: admin password, HEC, index, JSON parsing.
cat > "${STACK_DIR}/default.yml" <<EOF
splunk:
  password: "${SPLUNK_ADMIN_PASSWORD}"
  hec:
    enable: True
    ssl: True
    port: 8088
    token: ${HEC_TOKEN}
  conf:
    - key: indexes
      value:
        directory: /opt/splunk/etc/system/local
        content:
          ${INDEX_NAME}:
            homePath: \$SPLUNK_DB/${INDEX_NAME}/db
            coldPath: \$SPLUNK_DB/${INDEX_NAME}/colddb
            thawedPath: \$SPLUNK_DB/${INDEX_NAME}/thaweddb
            frozenTimePeriodInSecs: $(( RETENTION_DAYS * 86400 ))
            maxTotalDataSizeMB: $(( INDEX_MAX_GB * 1024 ))
    - key: props
      value:
        directory: /opt/splunk/etc/system/local
        content:
          "kube:container":
            KV_MODE: json
            SHOULD_LINEMERGE: false
            TRUNCATE: 100000
            FIELDALIAS-app: "kubernetes.labels.app AS app"
            FIELDALIAS-namespace: "kubernetes.namespace_name AS namespace"
            FIELDALIAS-pod: "kubernetes.pod_name AS pod"
            FIELDALIAS-container: "kubernetes.container_name AS container"
            FIELDALIAS-image: "kubernetes.container_image AS image"
EOF
chmod 600 "${STACK_DIR}/.env"
chmod 644 "${STACK_DIR}/docker-compose.yml"
# default.yml is mounted into the container and must be readable by the (non-root)
# Splunk user inside it. It holds the password + token, so the folder itself is
# root-only: nobody else on this server can reach the file.
chmod 644 "${STACK_DIR}/default.yml"
chmod 700 "${STACK_DIR}"

# ----------------------------- 4. start --------------------------------------
log "4/5 Pulling the Splunk image and starting the container"
cd "${STACK_DIR}"
docker compose pull
docker compose up -d

# ----------------------------- 5. wait + verify ------------------------------
log "5/5 Waiting for Splunk Web and HEC (first start takes about 3-8 minutes)"
ok=0
end=$(( SECONDS + WAIT_SECONDS ))
while [ "${SECONDS}" -lt "${end}" ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/en-US/account/login || true)"
  hec="$(curl -sk https://127.0.0.1:8088/services/collector/health || true)"
  if [ "${code}" = "200" ] && echo "${hec}" | grep -q 'HEC is healthy'; then ok=1; break; fi
  sleep 10
done
if [ "${ok}" -ne 1 ]; then
  docker logs --tail 40 splunk || true
  die "Splunk did not become healthy in ${WAIT_SECONDS}s. See the log lines above, or run: docker logs -f splunk"
fi

# Did the index get created from default.yml? (warn only; you can also create it in the UI)
if docker exec splunk /opt/splunk/bin/splunk btool indexes list "${INDEX_NAME}" 2>/dev/null | grep -q '^homePath'; then
  INDEX_STATE="created"
else
  INDEX_STATE="NOT FOUND - create it in Splunk Web: Settings > Indexes > New Index > name ${INDEX_NAME}"
fi

# Address Fluent Bit should send to: the server's public IPv4 (auto-assigned or Elastic) if it has one,
# otherwise its private IP. Uses IMDSv2, falls back to hostname.
IMDS_TOKEN="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token \
              -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
PUBLIC_IP="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
              http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
PRIVATE_IP="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
              http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
[ -n "${PRIVATE_IP}" ] || PRIVATE_IP="$(hostname -I | awk '{print $1}')"
# A real public IP looks like a number (an error page from IMDS does not)
[[ "${PUBLIC_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || PUBLIC_IP=""
SPLUNK_ADDR="${PUBLIC_IP:-${PRIVATE_IP}}"

cat > /root/splunk-hec-info.txt <<EOF
SPLUNK_HOST=${SPLUNK_ADDR}
SPLUNK_PORT=8088
SPLUNK_HEC_TOKEN=${HEC_TOKEN}
EOF

cat <<EOF

=============================================================================
 Splunk (Docker) is ready.

 Web UI      : http://<this-server-public-IP>:8000     user: admin
 HEC health  : OK (https://${SPLUNK_ADDR}:8088)
 Index       : ${INDEX_NAME}  -> ${INDEX_STATE}
 Image       : ${SPLUNK_IMAGE}

 Values for Fluent Bit (also saved in /root/splunk-hec-info.txt, root-only):
     SPLUNK_HOST=${SPLUNK_ADDR}
     SPLUNK_PORT=8088
     SPLUNK_HEC_TOKEN=${HEC_TOKEN}

 Handy:  cd ${STACK_DIR} && docker compose ps | logs -f | restart
=============================================================================
EOF
