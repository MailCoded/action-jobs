resource "oci_core_instance" "a1" {
  availability_domain = var.instance_availability_domain
  compartment_id      = local.compartment_ocid
  display_name        = var.instance_name
  shape               = "VM.Standard.A1.Flex"
  fault_domain        = var.fault_domain != "" ? var.fault_domain : null

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = local.arm_images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = local.subnet_id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  freeform_tags = local.tags

  # Bounds only the wait for RUNNING after launch or an in-place resize; the 45m defaults outlive the job.
  timeouts {
    create = "10m"
    update = "10m"
  }

  lifecycle {
    # Scheduled runs pass different AD/FD values and Oracle republishes images monthly;
    # none of that may ever trigger a replace of a live instance. A source_id change would
    # even be an in-place boot volume replacement that the delete check cannot see.
    ignore_changes = [availability_domain, fault_domain, source_details, metadata]
  }
}
