terraform {
  backend "oci" {
    key                 = "oracle-a1/terraform.tfstate"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
    # bucket, namespace and region are supplied via -backend-config at init.
  }
}
