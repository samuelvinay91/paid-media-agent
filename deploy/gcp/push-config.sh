#!/usr/bin/env bash
# Deliver local configuration to the VM and (re)start the services.
#
# Uploads .env, config/*.toml, and workspace/skills/ (company context included) over an IAP SSH
# tunnel, then runs docker compose on the VM and prints /health. Secrets are never printed.
# Run after `terraform apply` finishes its first boot, and again after every configuration change.
#
# Override the target with PMA_PROJECT, PMA_ZONE, and PMA_INSTANCE; defaults come from Terraform.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
TF_DIR=deploy/gcp

PROJECT=${PMA_PROJECT:-$(terraform -chdir="$TF_DIR" output -raw project_id)}
ZONE=${PMA_ZONE:-$(terraform -chdir="$TF_DIR" output -raw zone)}
INSTANCE=${PMA_INSTANCE:-$(terraform -chdir="$TF_DIR" output -raw instance_name)}
GCLOUD_FLAGS=(--project "$PROJECT" --zone "$ZONE" --tunnel-through-iap --quiet)

if [ ! -f .env ]; then
  echo "No .env found. Create it with 'uv run paid-media-agent setup' (or copy .env.example), then rerun." >&2
  exit 1
fi

# Host-owned secrets for the API and the approval flow. The API token prints once, to this terminal.
missing=()
grep -Eq '^PAID_MEDIA_API_TOKENS=.+' .env || missing+=(PAID_MEDIA_API_TOKENS)
grep -Eq '^PAID_MEDIA_APPROVAL_SIGNING_KEY=.+' .env || missing+=(PAID_MEDIA_APPROVAL_SIGNING_KEY)
if [ "${#missing[@]}" -gt 0 ]; then
  uv run paid-media-agent config generate "${missing[@]}"
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bundle/config" "$stage/bundle/skills"
cp .env "$stage/bundle/env"
cp config/*.toml "$stage/bundle/config/"
cp -R workspace/skills/. "$stage/bundle/skills/"
# COPYFILE_DISABLE keeps macOS resource forks out of the archive.
COPYFILE_DISABLE=1 tar -C "$stage/bundle" -czf "$stage/bundle.tgz" env config skills

echo "Uploading configuration to $INSTANCE ($PROJECT, $ZONE)..."
gcloud compute scp "${GCLOUD_FLAGS[@]}" "$stage/bundle.tgz" "$INSTANCE:/tmp/pma-bundle.tgz"

gcloud compute ssh "$INSTANCE" "${GCLOUD_FLAGS[@]}" --command 'sudo bash -s' <<'REMOTE'
set -euo pipefail
APP=/opt/paid-media-agent
work=$(mktemp -d)
tar -C "$work" -xzf /tmp/pma-bundle.tgz
rm -f /tmp/pma-bundle.tgz
install -o pma -g pma -m 600 "$work/env" "$APP/.env"
cp "$work"/config/*.toml "$APP/config/"
cp -R "$work"/skills/. "$APP/workspace/skills/"
chown -R pma:pma "$APP/config" "$APP/workspace/skills"
rm -rf "$work"

profile=()
if grep -Eq '^SLACK_BOT_TOKEN=.+' "$APP/.env" && grep -Eq '^SLACK_APP_TOKEN=.+' "$APP/.env"; then
  profile=(--profile slack)
  echo "Slack Socket Mode tokens present: starting the Slack worker too."
else
  echo "No Slack tokens in .env: starting the API and Postgres only."
fi
cd "$APP"
sudo -u pma docker compose "${profile[@]}" up -d --build --remove-orphans

for _ in $(seq 1 45); do
  if health=$(curl -fsS http://127.0.0.1:8080/health 2>/dev/null); then
    echo "health: $health"
    exit 0
  fi
  sleep 2
done
echo "API did not become healthy within 90 seconds; last log lines:" >&2
sudo -u pma docker compose logs --tail 40 api >&2
exit 1
REMOTE
