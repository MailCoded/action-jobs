locals {
  create_network = var.existing_subnet_id == ""
  subnet_id      = local.create_network ? oci_core_subnet.public[0].id : var.existing_subnet_id

  tags = {
    ManagedBy = "Terraform"
    Hub       = "freebie-hub"
    Module    = "oracle-a1"
  }
}

resource "oci_core_vcn" "main" {
  count = local.create_network ? 1 : 0

  compartment_id = local.compartment_ocid
  display_name   = "${var.instance_name}-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "a1vcn"
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "main" {
  count = local.create_network ? 1 : 0

  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main[0].id
  display_name   = "${var.instance_name}-igw"
  enabled        = true
  freeform_tags  = local.tags
}

resource "oci_core_route_table" "public" {
  count = local.create_network ? 1 : 0

  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main[0].id
  display_name   = "${var.instance_name}-rt"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main[0].id
  }
}

resource "oci_core_security_list" "public" {
  count = local.create_network ? 1 : 0

  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main[0].id
  display_name   = "${var.instance_name}-sl"
  freeform_tags  = local.tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    source   = var.ssh_allowed_cidr
    protocol = "6"

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  count = local.create_network ? 1 : 0

  compartment_id             = local.compartment_ocid
  vcn_id                     = oci_core_vcn.main[0].id
  display_name               = "${var.instance_name}-public"
  cidr_block                 = "10.0.1.0/24"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public[0].id
  security_list_ids          = [oci_core_security_list.public[0].id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.tags
}
