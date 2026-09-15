# Paid Media Agent on one Compute Engine VM.
#
# Private VPC with Cloud NAT for egress, SSH only through IAP, a dedicated service account, and
# daily boot-disk snapshots. The VM bootstraps itself from startup.sh (Docker, checkout, image
# build, report cron). Configuration and secrets arrive later through push-config.sh.

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_project_service" "apis" {
  for_each           = toset(["compute.googleapis.com", "iap.googleapis.com", "aiplatform.googleapis.com"])
  service            = each.key
  disable_on_destroy = false
}

# A freshly enabled Compute Engine API takes a minute or two to propagate; without this wait,
# disk and policy creation on a new project fails with a 403 saying the API is not enabled.
resource "time_sleep" "api_propagation" {
  depends_on      = [google_project_service.apis]
  create_duration = "90s"
}

resource "google_compute_network" "net" {
  name                    = "${var.name}-net"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "${var.name}-subnet"
  region                   = var.region
  network                  = google_compute_network.net.id
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true
}

# The VM has no public IP. GitHub, Docker Hub, Slack, Pipeboard, and model APIs are reached via NAT.
resource "google_compute_router" "router" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.net.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# The only ingress rule: SSH from Google's IAP TCP-forwarding range.
resource "google_compute_firewall" "iap_ssh" {
  name          = "${var.name}-allow-iap-ssh"
  network       = google_compute_network.net.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [var.name]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_service_account" "vm" {
  account_id   = "${var.name}-vm"
  display_name = "Paid Media Agent VM"
}

resource "google_project_iam_member" "vm_observability" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])
  project  = var.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.vm.email}"
}

# Vertex AI calls authenticate as this service account through the metadata server: no model
# API key is stored anywhere on the VM.
resource "google_project_iam_member" "vm_vertex_ai" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

resource "google_compute_disk" "boot" {
  name  = "${var.name}-boot"
  zone  = var.zone
  image = data.google_compute_image.debian.self_link
  size  = var.disk_size_gb
  type  = "pd-balanced"

  depends_on = [time_sleep.api_propagation]

  lifecycle {
    # A newer Debian image must not force a disk rebuild; the VM patches itself in place.
    ignore_changes = [image]
  }
}

resource "google_compute_resource_policy" "daily_snapshot" {
  name       = "${var.name}-daily-snapshot"
  region     = var.region
  depends_on = [time_sleep.api_propagation]

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "04:00"
      }
    }
    retention_policy {
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      storage_locations = [var.region]
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "boot_snapshots" {
  name = google_compute_resource_policy.daily_snapshot.name
  disk = google_compute_disk.boot.name
  zone = var.zone
}

resource "google_compute_instance" "vm" {
  name                      = var.name
  machine_type              = var.machine_type
  zone                      = var.zone
  tags                      = [var.name]
  labels                    = { app = "paid-media-agent" }
  allow_stopping_for_update = true
  deletion_protection       = var.deletion_protection

  boot_disk {
    source      = google_compute_disk.boot.self_link
    auto_delete = false
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config block, so no external IP.
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"
    pma-repo-url   = var.repo_url
    pma-repo-ref   = var.repo_ref
  }
  metadata_startup_script = file("${path.module}/startup.sh")

  depends_on = [google_compute_router_nat.nat]
}
