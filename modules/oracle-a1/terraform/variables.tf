variable "tenancy_ocid" {
  description = "Tenancy OCID (root compartment). Used for image lookup and as the default compartment."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "tenancy_ocid must start with ocid1.tenancy."
  }
}

variable "compartment_ocid" {
  description = "Compartment for all resources. Empty means the root compartment."
  type        = string
  default     = ""

  validation {
    condition     = var.compartment_ocid == "" || can(regex("^ocid1\\.(compartment|tenancy)\\.", var.compartment_ocid))
    error_message = "compartment_ocid must be empty or start with ocid1.compartment. (or ocid1.tenancy.)."
  }
}

variable "region" {
  description = "OCI region. Always Free A1 can only be launched in the tenancy's home region."
  type        = string
  default     = "ap-sydney-1"

  validation {
    condition     = can(regex("^[a-z]+(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must look like ap-sydney-1."
  }
}

variable "instance_availability_domain" {
  description = "Availability domain for the launch attempt. Set by run.sh on every attempt; ignored after creation."
  type        = string
  default     = ""
}

variable "fault_domain" {
  description = "Fault domain for the launch attempt. Empty lets OCI pick any fault domain with capacity."
  type        = string
  default     = ""

  validation {
    condition     = var.fault_domain == "" || can(regex("^FAULT-DOMAIN-[1-3]$", var.fault_domain))
    error_message = "fault_domain must be empty or FAULT-DOMAIN-1, FAULT-DOMAIN-2 or FAULT-DOMAIN-3."
  }
}

variable "instance_name" {
  description = "Display name of the instance and prefix for network resource names."
  type        = string
  default     = "oracle-free-a1"

  validation {
    condition     = length(trimspace(var.instance_name)) > 0
    error_message = "instance_name must not be empty."
  }
}

variable "ocpus" {
  description = "A1 OCPUs. The Always Free allowance is 2 OCPU in total."
  type        = number
  default     = 2

  validation {
    condition     = var.ocpus >= 1 && var.ocpus <= 4 && floor(var.ocpus) == var.ocpus
    error_message = "ocpus must be a whole number between 1 and 4 (Always Free allows 2 in total)."
  }
}

variable "memory_in_gbs" {
  description = "A1 memory in GB. The Always Free allowance is 12 GB in total."
  type        = number
  default     = 12

  validation {
    condition     = var.memory_in_gbs >= 1 && var.memory_in_gbs <= 24
    error_message = "memory_in_gbs must be between 1 and 24 (Always Free allows 12 in total)."
  }
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size. Counts towards the 200 GB Always Free block storage allowance."
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_size_in_gbs >= 50 && var.boot_volume_size_in_gbs <= 200 && floor(var.boot_volume_size_in_gbs) == var.boot_volume_size_in_gbs
    error_message = "boot_volume_size_in_gbs must be a whole number between 50 and 200."
  }
}

variable "ssh_public_key" {
  description = "SSH public key content (not a path) for the default user's authorized_keys."
  type        = string
  # Not secret, but keeps a mistakenly pasted private key out of plan output and error messages.
  sensitive = true

  validation {
    condition     = can(regex("^(ssh-ed25519 |ssh-rsa |ecdsa-sha2-)", var.ssh_public_key))
    error_message = "ssh_public_key must be public key text starting with 'ssh-ed25519 ', 'ssh-rsa ' or 'ecdsa-sha2-', not a file path or a private key."
  }
}

variable "os_name" {
  description = "Platform image operating system, as reported by OCI."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "os_version" {
  description = "Platform image operating system version."
  type        = string
  default     = "24.04"
}

variable "existing_subnet_id" {
  description = "OCID of an existing public subnet. Empty creates a minimal VCN and public subnet."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_subnet_id == "" || can(regex("^ocid1\\.subnet\\.", var.existing_subnet_id))
    error_message = "existing_subnet_id must be empty or start with ocid1.subnet."
  }
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to reach port 22 through the created security list. Narrow this to your own address."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "ssh_allowed_cidr must be a valid CIDR block, e.g. 203.0.113.4/32."
  }
}
