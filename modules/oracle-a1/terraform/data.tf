locals {
  compartment_ocid = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid

  # The provider's regex filter is unanchored, so "aarch64" also matches Minimal builds,
  # which Oracle says not to use on Arm shapes.
  arm_images = [
    for image in data.oci_core_images.arm.images : image
    if !strcontains(image.display_name, "Minimal") && !strcontains(image.display_name, "GPU")
  ]
}

data "oci_core_images" "arm" {
  compartment_id           = var.tenancy_ocid
  operating_system         = var.os_name
  operating_system_version = var.os_version
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"

  filter {
    name   = "display_name"
    values = ["aarch64"]
    regex  = true
  }

  lifecycle {
    postcondition {
      condition = length([
        for image in self.images : image
        if !strcontains(image.display_name, "Minimal") && !strcontains(image.display_name, "GPU")
      ]) > 0
      error_message = "No AVAILABLE ${var.os_name} ${var.os_version} aarch64 image for VM.Standard.A1.Flex was found in ${var.region}. Check os_name/os_version, and that the automation group may read instance-images in the tenancy."
    }
  }
}

# A check block only warns; the postcondition above is what stops the run.
check "arm_image_found" {
  assert {
    condition     = length(local.arm_images) > 0
    error_message = "No ${var.os_name} ${var.os_version} aarch64 image for VM.Standard.A1.Flex in ${var.region}."
  }
}
