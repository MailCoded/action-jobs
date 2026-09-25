locals {
  image_id   = oci_core_instance.a1.source_details[0].source_id
  used_image = try([for image in data.oci_core_images.arm.images : image if image.id == local.image_id][0], null)
  # Prefer the image the VM was built from; os_name may have changed since.
  ssh_user  = strcontains(lower(try(local.used_image.operating_system, var.os_name)), "ubuntu") ? "ubuntu" : "opc"
  public_ip = oci_core_instance.a1.public_ip
}

output "instance_id" {
  value = oci_core_instance.a1.id
}

output "instance_name" {
  value = oci_core_instance.a1.display_name
}

output "public_ip" {
  value = oci_core_instance.a1.public_ip
}

output "private_ip" {
  value = oci_core_instance.a1.private_ip
}

output "availability_domain" {
  value = oci_core_instance.a1.availability_domain
}

output "fault_domain" {
  value = oci_core_instance.a1.fault_domain
}

output "region" {
  value = var.region
}

output "ocpus" {
  value = oci_core_instance.a1.shape_config[0].ocpus
}

output "memory_in_gbs" {
  value = oci_core_instance.a1.shape_config[0].memory_in_gbs
}

# The image list only holds recent builds, so fall back to the OCID once the used one rotates out.
output "image_name" {
  value = try(local.used_image.display_name, local.image_id)
}

output "ssh_command" {
  value = local.public_ip != null && local.public_ip != "" ? "ssh ${local.ssh_user}@${local.public_ip}" : null
}
