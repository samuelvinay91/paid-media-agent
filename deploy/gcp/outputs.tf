output "project_id" {
  value = var.project_id
}

output "zone" {
  value = var.zone
}

output "instance_name" {
  value = google_compute_instance.vm.name
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.vm.name} --project ${var.project_id} --zone ${var.zone} --tunnel-through-iap"
}

output "startup_log_command" {
  value = "gcloud compute ssh ${google_compute_instance.vm.name} --project ${var.project_id} --zone ${var.zone} --tunnel-through-iap --command 'sudo tail -f /var/log/paid-media-startup.log'"
}
