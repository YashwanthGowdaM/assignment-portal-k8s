#!/usr/bin/env bash
# =============================================================================
# bootstrap-splunk.sh
# Installs and configures a single-instance Splunk Enterprise server for
# receiving Kubernetes logs from Fluent Bit.
#
# Run ONCE, as root, on a fresh Ubuntu 22.04 / 24.04 EC2 instance (x86_64):
#
#   export SPLUNK_DEB_URL='<wget link copied from splunk.com>'
#   export SPLUNK_ADMIN_PASSWORD='<choose a strong password, 8+ chars>'
#   sudo -E bash bootstrap-splunk.sh
#
# What it does:
#   1. Formats + mounts the extra EBS data disk at /opt/splunk (survives re-installs)
#   2. Installs Splunk from the .deb package
#   3. Creates the "k8s_logs" index (30-day retention, size capped)
#   4. Turns on the HTTP Event Collector (HEC) on port 8088 and creates a token
#   5. Sets the admin password, enables start-on-boot, starts Splunk
#   6. Prints the values you need for Fluent Bit
#
# Safe to re-run: it skips steps that are already done and reuses the HEC token.
# =============================================================================
set -euo pipefail

# ----------------------------- settings you may change -----------------------
SPLUNK_HOME="/opt/splunk"
INDEX_NAME="${INDEX_NAME:-k8s_logs}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"          # events older than this are deleted
INDEX_MAX_GB="${INDEX_MAX_GB:-80}"              # hard size cap for the index
HEC_NAME="${HEC_NAME:-k8s-fluent-bit}"
DATA_DEVICE="${DATA_DEVICE:-}"                  # e.g. /dev/nvme1n1 (auto-detected if empty)
APP_DIR="${SPLUNK_HOME}/etc/apps/k8s_logging"

# ----------------------------- helpers ---------------------------------------
log()  { printf '\n\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------- pre-flight checks -----------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo -E bash $0"
: "${SPLUNK_DEB_URL:?Set SPLUNK_DEB_URL (the .deb wget link from splunk.com) - see README step 3.2}"
: "${SPLUNK_ADMIN_PASSWORD:?Set SPLUNK_ADMIN_PASSWORD (8+ characters)}"
[ "${#SPLUNK_ADMIN_PASSWORD}" -ge 8 ] || die "SPLUNK_ADMIN_PASSWORD must be at least 8 characters"
[ "$(uname -m)" = "x86_64" ] || die "This script expects an x86_64 instance (not Graviton/ARM)"
. /etc/os-release
case "${VERSION_ID}" in
  22.04|24.04) ;;
  *) die "Ubuntu 22.04 or 24.04 expected, found ${PRETTY_NAME}" ;;
esac

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

if mountpoint -q "${SPLUNK_HOME}"; then
  log "1/6 ${SPLUNK_HOME} is already a mount point - skipping disk setup"
else
  [ -n "${DATA_DEVICE}" ] || DATA_DEVICE="$(detect_data_device)"
  [ -n "${DATA_DEVICE}" ] || die "No spare data disk found. Attach the extra EBS volume, or set DATA_DEVICE=/dev/xxx"
  log "1/6 Preparing data disk ${DATA_DEVICE}"
  if ! blkid "${DATA_DEVICE}" >/dev/null 2>&1; then
    log "    No filesystem found - formatting ${DATA_DEVICE} as ext4"
    mkfs.ext4 -q -L splunkdata "${DATA_DEVICE}"
  else
    log "    Existing filesystem found - keeping it (data is NOT erased)"
  fi
  mkdir -p "${SPLUNK_HOME}"
  UUID="$(blkid -s UUID -o value "${DATA_DEVICE}")"
  grep -q "${UUID}" /etc/fstab || echo "UUID=${UUID} ${SPLUNK_HOME} ext4 defaults,nofail 0 2" >> /etc/fstab
  mount "${SPLUNK_HOME}"
fi

# ----------------------------- 2. install Splunk -----------------------------
if [ -x "${SPLUNK_HOME}/bin/splunk" ]; then
  log "2/6 Splunk is already installed - skipping download"
else
  log "2/6 Downloading and installing Splunk"
  apt-get update -y
  apt-get install -y wget curl
  wget -q --show-progress -O /tmp/splunk.deb "${SPLUNK_DEB_URL}"
  dpkg -i /tmp/splunk.deb
  rm -f /tmp/splunk.deb
fi
id splunk >/dev/null 2>&1 || useradd -r -m -d "${SPLUNK_HOME}" splunk

# ----------------------------- 3 + 4. index and HEC --------------------------
log "3/6 Writing index + HEC configuration (app: k8s_logging)"
mkdir -p "${APP_DIR}/local" "${APP_DIR}/default"

cat > "${APP_DIR}/default/app.conf" <<'EOF'
[install]
state = enabled

[ui]
is_visible = false
label = Kubernetes Logging

[launcher]
version = 1.0.0
description = Index, HEC input and parsing settings for Fluent Bit logs from EKS
EOF

cat > "${APP_DIR}/local/indexes.conf" <<EOF
[${INDEX_NAME}]
homePath   = \$SPLUNK_DB/${INDEX_NAME}/db
coldPath   = \$SPLUNK_DB/${INDEX_NAME}/colddb
thawedPath = \$SPLUNK_DB/${INDEX_NAME}/thaweddb
# delete events older than ${RETENTION_DAYS} days
frozenTimePeriodInSecs = $(( RETENTION_DAYS * 86400 ))
# never let this index grow beyond ${INDEX_MAX_GB} GB
maxTotalDataSizeMB = $(( INDEX_MAX_GB * 1024 ))
EOF

# Fluent Bit sends each event as JSON; this makes Splunk split it into searchable fields
# (kubernetes.namespace_name, kubernetes.pod_name, log, stream, ...).
cat > "${APP_DIR}/local/props.conf" <<'EOF'
[kube:container]
KV_MODE = json
SHOULD_LINEMERGE = false
TRUNCATE = 100000
EOF

# Reuse the existing token if this script is re-run, otherwise create one.
if [ -f "${APP_DIR}/local/inputs.conf" ] && grep -q '^token' "${APP_DIR}/local/inputs.conf"; then
  HEC_TOKEN="$(awk -F' *= *' '/^token/{print $2; exit}' "${APP_DIR}/local/inputs.conf")"
  log "    Re-using existing HEC token"
else
  HEC_TOKEN="$(cat /proc/sys/kernel/random/uuid)"
fi

cat > "${APP_DIR}/local/inputs.conf" <<EOF
# Global HTTP Event Collector settings: on, HTTPS, port 8088
[http]
disabled = 0
enableSSL = 1
port = 8088

# The token Fluent Bit uses. It may only write to the ${INDEX_NAME} index.
[http://${HEC_NAME}]
disabled = 0
token = ${HEC_TOKEN}
index = ${INDEX_NAME}
indexes = ${INDEX_NAME}
sourcetype = kube:container
EOF

# ----------------------------- 5. admin user + service -----------------------
log "4/6 Setting admin password and permissions"
if [ ! -f "${SPLUNK_HOME}/etc/passwd" ]; then
  cat > "${SPLUNK_HOME}/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = admin
PASSWORD = ${SPLUNK_ADMIN_PASSWORD}
EOF
  chmod 600 "${SPLUNK_HOME}/etc/system/local/user-seed.conf"
else
  log "    Admin account already exists - leaving it unchanged"
fi
chown -R splunk:splunk "${SPLUNK_HOME}"

log "5/6 Enabling start-on-boot and starting Splunk (first start takes 1-2 minutes)"
if [ ! -f /etc/systemd/system/Splunkd.service ]; then
  "${SPLUNK_HOME}/bin/splunk" enable boot-start -systemd-managed 1 -user splunk \
      --accept-license --answer-yes --no-prompt
fi
systemctl daemon-reload
systemctl enable Splunkd >/dev/null 2>&1 || true
systemctl restart Splunkd

# ----------------------------- 6. wait + verify ------------------------------
log "6/6 Waiting for Splunk Web and HEC to come up"
ok=0
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/en-US/account/login || true)"
  hec="$(curl -sk https://127.0.0.1:8088/services/collector/health || true)"
  if [ "${code}" = "200" ] && echo "${hec}" | grep -q 'HEC is healthy'; then ok=1; break; fi
  sleep 5
done
[ "${ok}" -eq 1 ] || die "Splunk did not become healthy in 5 minutes. Check: sudo tail -n 50 ${SPLUNK_HOME}/var/log/splunk/splunkd.log"

# Private IP (what Fluent Bit uses). IMDSv2 first, fall back to hostname.
IMDS_TOKEN="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token \
              -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
PRIVATE_IP="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
              http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
[ -n "${PRIVATE_IP}" ] || PRIVATE_IP="$(hostname -I | awk '{print $1}')"

umask 077
cat > /root/splunk-hec-info.txt <<EOF
SPLUNK_HOST=${PRIVATE_IP}
SPLUNK_PORT=8088
SPLUNK_HEC_TOKEN=${HEC_TOKEN}
EOF

cat <<EOF

=============================================================================
 Splunk is ready.

 Web UI      : http://<this-server-public-IP>:8000     user: admin
 HEC health  : OK (https://${PRIVATE_IP}:8088)
 Index       : ${INDEX_NAME}  (kept ${RETENTION_DAYS} days, max ${INDEX_MAX_GB} GB)

 Values for Fluent Bit (also saved in /root/splunk-hec-info.txt, root-only):
     SPLUNK_HOST=${PRIVATE_IP}
     SPLUNK_PORT=8088
     SPLUNK_HEC_TOKEN=${HEC_TOKEN}
=============================================================================
EOF
