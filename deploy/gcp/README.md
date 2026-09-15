# Paid Media Agent on a Compute Engine VM

One VM runs the self-hosted API, the Slack worker, and Postgres using the repository's own
`docker-compose.yml`. Terraform creates a private VPC, Cloud NAT, IAP-only SSH, a dedicated
service account, and daily boot-disk snapshots. The VM bootstraps itself from `startup.sh`;
`push-config.sh` delivers your configuration afterwards so no secret ever enters Terraform state
or a build image.

## Prerequisites

- A GCP project with billing enabled.
- `gcloud` signed in (`gcloud auth login`) as a project Owner, or Editor plus
  `roles/iap.tunnelResourceAccessor` and `roles/compute.osAdminLogin`.
- Terraform 1.5 or newer.
- Locally: `uv sync` done, so `push-config.sh` can generate API tokens.

## 0. Create a project (optional)

```bash
gcloud projects create <project-id> --name "Paid Media Agent"
gcloud billing projects link <project-id> --billing-account <BILLING_ACCOUNT_ID>
```

`gcloud billing accounts list` shows the billing account id. Terraform enables the Compute,
IAP, and Vertex AI APIs itself.

## 1. Provision

```bash
cd deploy/gcp
cp terraform.tfvars.example terraform.tfvars   # set project_id; repo_url if you deploy a fork
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)
terraform init
terraform apply
```

The first boot installs Docker, clones the repository at `repo_ref`, and builds the image. On an
e2-small this takes about ten minutes. Watch it with the `startup_log_command` output, and wait for
`paid-media startup complete`.

## 2. Configure locally, then push

```bash
uv run paid-media-agent setup        # model key, ad accounts, Slack tokens -> .env, config/accounts.toml
./deploy/gcp/push-config.sh
```

`push-config.sh` generates `PAID_MEDIA_API_TOKENS` and `PAID_MEDIA_APPROVAL_SIGNING_KEY` if they
are missing (the API token prints once), uploads `.env`, `config/*.toml`, and `workspace/skills/`,
restarts Compose, and prints `/health`. The Slack worker starts only when both Slack Socket Mode
tokens are set. Rerun the script after any configuration or company-context change.

Docker Compose overrides `DATABASE_URL`, `PAID_MEDIA_RUNTIME`, and `PAID_MEDIA_API_HOST`, so the
local values of those three do not matter.

## Vertex AI models

The VM's service account carries `roles/aiplatform.user`, so Gemini and Claude on Vertex AI work
with no model API key anywhere on the machine. Put these in your local `.env` before pushing:

```
PAID_MEDIA_MODEL=google_vertexai:gemini-3.8-flash
PAID_MEDIA_TOOL_SELECTOR_MODEL=google_vertexai:gemini-3.5-flash-lite
GOOGLE_CLOUD_PROJECT=<project_id from terraform.tfvars>
GOOGLE_CLOUD_LOCATION=global
```

`global` matters: Gemini 3 models return 404 from regional endpoints such as `us-central1`, which
serve only Gemini 2.5 and older. `gemini-2.5-pro` works from either. Model metadata can list a
model as available that inference still rejects, so confirm a new id with one small request
before switching.

For Claude, enable the model in Model Garden first, then use the Vertex model id, for example
`google_anthropic_vertex:claude-sonnet-4-6` or `google_anthropic_vertex:claude-opus-5`. Claude
models newer than Sonnet 4.6 also need the `global` location. Claude on Vertex uses the portable
tool selector.

To run `ask` locally against Vertex, run `gcloud auth application-default login` once; the VM
needs nothing extra.

## 3. Verify

- `/health` reports `"persistence": "postgres"`.
- Mention the app in Slack, or call the API from the VM:
  `curl -H "Authorization: Bearer <token>" -X POST localhost:8080/threads/t1/messages -d '{"text":"Compare last week"}' -H 'content-type: application/json'`
- Logs: SSH in, then `cd /opt/paid-media-agent && sudo -u pma docker compose logs -f`.

## Scheduled reports

Cron on the VM runs the weekly report Monday 13:00 UTC and the monthly report on the 1st at
13:00 UTC, matching the managed defaults. Edit `/etc/cron.d/paid-media-reports` on the VM (or
`startup.sh` before provisioning) to change the timing. Output lands in the `workspace` Docker
volume; copy it out with `sudo -u pma docker compose cp api:/app/workspace/out ./out`, or download
through the authenticated artifacts route. Run logs are in `/opt/paid-media-agent/workspace/logs/`.

## Updating the code

Push to the branch named by `repo_ref`, then on the VM:

```bash
sudo google_metadata_script_runner startup   # fetch, checkout, rebuild image
```

and run `./deploy/gcp/push-config.sh` locally to restart the containers. To pin a different
commit, change `repo_ref` in `terraform.tfvars`, run `terraform apply`, and repeat the two steps.

## Operations

| Task | Command |
| --- | --- |
| SSH | `terraform output -raw ssh_command`, then run it |
| Stop mutations | `sudo -u pma docker compose exec api paid-media-agent writes kill-switch on` |
| Resize | `gcloud compute instances set-machine-type paid-media-agent --machine-type e2-medium --zone <zone>` after stopping the VM |
| Restore | Create a disk from a snapshot in the console, then swap it in with `terraform import` or a new VM |
| Tear down | `terraform destroy` (set `deletion_protection = false` first if enabled). Snapshots are kept; delete them by hand |

## Approximate monthly cost (us-central1)

| Item | USD |
| --- | --- |
| e2-small, sustained use | 12 |
| 20 GB pd-balanced | 2 |
| Cloud NAT gateway plus egress | 1 to 3 |
| Snapshots, 14-day retention | under 1 |

Model, Pipeboard, and Slack charges are separate.

## Security notes

- No public IP. The only ingress is SSH via IAP. The API binds to localhost on the VM; Postgres
  is reachable only inside the Compose network.
- Secrets live in `/opt/paid-media-agent/.env`, mode 0600, owned by `pma`. Disk snapshots contain
  that file, so restrict who can read snapshots in the project.
- OS Login is on, so SSH access follows IAM; there are no static SSH keys in metadata.
- Live ad-account writes stay off by default. Follow `docs/operations/live-write-runbook.md`
  before enabling them.
