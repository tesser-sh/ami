packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.2"
    }
  }
}

variable "source_sha" {
  type        = string
  description = "The commit of this repo being built."
}

locals {
  ami_name = "tesser-box-${formatdate("YYYYMMDDhhmmss", timestamp())}-${substr(var.source_sha, 0, 7)}"
  tags = {
    Name            = local.ami_name
    "tesser:ami"    = "box"
    "tesser:source" = var.source_sha
  }
}

source "amazon-ebs" "box" {
  region      = "us-west-2"
  ami_regions = ["us-west-2", "us-east-1"]

  # Ubuntu 24.04 LTS (amd64), pinned by id. The owner filter makes Packer
  # refuse it unless it is Canonical's.
  source_ami_filter {
    filters = {
      image-id = "ami-0ac74609c6396bed3"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  instance_type = "m7a.large"
  subnet_filter {
    filters = {
      "tag:Name" = "devcloud-public"
    }
  }
  security_group_filter {
    filters = {
      "tag:Name" = "tesser-ami-build"
    }
  }
  associate_public_ip_address = true
  ssh_username                = "ubuntu"
  ssh_interface               = "public_ip"
  temporary_key_pair_type     = "ed25519"

  ami_name        = local.ami_name
  ami_description = "tesser box image, github.com/tesser-sh/ami at ${var.source_sha}"
  # A public AMI needs an unencrypted snapshot. Boxes launched from it are
  # still encrypted: tesser asks for encryption on every launch.
  encrypt_boot = false
  ami_groups   = ["all"]

  run_tags        = local.tags
  run_volume_tags = local.tags

  aws_polling {
    delay_seconds = 30
    max_attempts  = 120
  }
}

build {
  sources = ["source.amazon-ebs.box"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/tesser"]
  }

  provisioner "file" {
    sources     = ["boot", "config", "verify"]
    destination = "/tmp/tesser/"
  }

  provisioner "shell" {
    scripts          = ["setup.sh", "cleanup.sh"]
    environment_vars = ["TESSER_FILES=/tmp/tesser"]
    execute_command  = "chmod +x {{ .Path }}; sudo {{ .Vars }} {{ .Path }}"
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
