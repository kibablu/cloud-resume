terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "3.5.0"
    }
  }
}

# GCP provider
provider "google" {
  #  credentials = file(var.gcp_svc_key)
  project = var.gcp_project
  region  = var.gcp_region
}

# GCP beta provider
provider "google-beta" {
  #  credentials = file(var.gcp_svc_key)
  project = var.gcp_project
  region  = var.gcp_region
}
# Bucket to store website
resource "google_storage_bucket" "website" {
  name          = var.gcs_bucket
  project       = var.gcp_project
  storage_class = "STANDARD"
  location      = "US"
}

# Make new objects public
resource "google_storage_bucket_iam_member" "website_read" {
  bucket = google_storage_bucket.website.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}
#Upload files to cloud storage Bucket
resource "null_resource" "upload_folder_content" {
  provisioner "local-exec" {
    command = "gsutil -m rsync -d -r ${var.static_folder_path} gs://${var.gcs_bucket}/"
  }
}

# Reserve an external IP
resource "google_compute_global_address" "website" {
  name         = "cdn-public-address"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"
  project      = var.gcp_project
}

# Get the managed DNS zone
resource "google_dns_managed_zone" "website" {
  name        = "websitecdn-zone"
  dns_name    = "example-${random_id.rnd.hex}.com."
  description = "Example DNS zone"
}
resource "random_id" "rnd" {
  byte_length = 4
}

# Add the IP to the DNS
resource "google_dns_record_set" "website" {
  managed_zone = google_dns_managed_zone.website.name # Name of your managed DNS zone
  name         = google_dns_managed_zone.website.dns_name
  type         = "A"
  ttl          = 3600 # 1 hour
  rrdatas      = [google_compute_global_address.website.address]
  project      = var.gcp_project
}

# Add the bucket as a CDN backend
resource "google_compute_backend_bucket" "website" {
  provider    = google
  name        = "website-backend"
  description = "Contains files needed by the website"
  bucket_name = google_storage_bucket.website.name
  enable_cdn  = true
}

# Create HTTPS certificate
resource "google_compute_managed_ssl_certificate" "website" {
  provider = google-beta
  name     = "website-cert"
  managed {
    domains = [google_dns_record_set.website.name]
  }
}

# GCP URL MAP
resource "google_compute_url_map" "website" {
  provider        = google
  name            = "website-url-map"
  default_service = google_compute_backend_bucket.website.self_link
}

# GCP target proxy
resource "google_compute_target_https_proxy" "website" {
  provider         = google
  name             = "website-target-proxy"
  url_map          = google_compute_url_map.website.self_link
  ssl_certificates = [google_compute_managed_ssl_certificate.website.self_link]
}

# GCP forwarding rule
resource "google_compute_global_forwarding_rule" "default" {
  provider              = google
  name                  = "website-forwarding-rule"
  load_balancing_scheme = "EXTERNAL"
  ip_address            = google_compute_global_address.website.address
  ip_protocol           = "TCP"
  port_range            = "443"
  target                = google_compute_target_https_proxy.website.self_link
}
