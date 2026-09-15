#!/usr/bin/env bash
# Compute Engine startup script for Paid Media Agent.
#
# Runs as root on every boot; every step is idempotent. It prepares the host and builds the
# image but never starts the agent: that needs the operator's .env, which push-config.sh delivers
# over IAP SSH. Re-run by hand with: sudo google_metadata_script_runner startup
set -euo pipefail
exec > >(tee -a /var/log/paid-media-startup.log) 2>&1
echo "== paid-media startup $(date -u +%FT%TZ)"

APP_DIR=/opt/paid-media-agent
APP_USER=pma
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg git cron unattended-upgrades

META=http://metadata.google.internal/computeMetadata/v1/instance/attributes
meta() { curl -fsS -H 'Metadata-Flavor: Google' "$META/$1"; }
REPO_URL=$(meta pma-repo-url)
REPO_REF=$(meta pma-repo-ref)

# 2 GB swap: a shared-core VM has 2 GB RAM, and the image build plus two agent processes need headroom.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile

# Docker Engine and the Compose plugin from Docker's own repository.
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $codename stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
systemctl enable --now docker

# Unprivileged service user that owns the checkout and runs Compose.
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$APP_USER"
usermod -aG docker "$APP_USER"

# Checkout pinned to the ref in instance metadata. Changing the metadata and re-running updates it.
# The checkout is owned by the service user, so root's git needs it marked safe on re-runs.
git config --system --get-all safe.directory 2>/dev/null | grep -qx "$APP_DIR" \
  || git config --system --add safe.directory "$APP_DIR"
if [ ! -d "$APP_DIR/.git" ]; then
  git clone --quiet "$REPO_URL" "$APP_DIR"
fi
git -C "$APP_DIR" remote set-url origin "$REPO_URL"
git -C "$APP_DIR" fetch --quiet --tags origin
if git -C "$APP_DIR" rev-parse --verify --quiet "origin/$REPO_REF" >/dev/null; then
  git -C "$APP_DIR" checkout --quiet --detach "origin/$REPO_REF"
else
  git -C "$APP_DIR" checkout --quiet --detach "$REPO_REF"
fi
echo "checked out $(git -C "$APP_DIR" rev-parse --short HEAD) from $REPO_URL ($REPO_REF)"

# Placeholder .env so Compose can interpolate; push-config.sh replaces it with the real one.
if [ ! -f "$APP_DIR/.env" ]; then
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
fi
chmod 600 "$APP_DIR/.env"
mkdir -p "$APP_DIR/workspace/logs" "$APP_DIR/workspace/skills/company-context"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# Build now so the first push-config.sh only has to start containers.
sudo -u "$APP_USER" docker compose --project-directory "$APP_DIR" build

# Scheduled reports mirror the managed defaults: Monday 13:00 UTC weekly, the 1st at 13:00 UTC monthly.
cat > /etc/cron.d/paid-media-reports <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 13 * * 1 $APP_USER cd $APP_DIR && docker compose exec -T api paid-media-agent report --cadence weekly >> $APP_DIR/workspace/logs/report-weekly.log 2>&1
0 13 1 * * $APP_USER cd $APP_DIR && docker compose exec -T api paid-media-agent report --cadence monthly >> $APP_DIR/workspace/logs/report-monthly.log 2>&1
EOF
chmod 644 /etc/cron.d/paid-media-reports
systemctl enable --now cron

echo "== paid-media startup complete"
