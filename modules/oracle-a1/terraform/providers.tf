provider "oci" {
  region              = var.region
  retries_config_file = "${path.module}/retries.json"
}
