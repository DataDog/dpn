
# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

# module file to hold sandbox global configurations and reduce terraforming of individual sandboxes.

provider "aws" {
  region = contains(["REPLACE_ME", ""], var.aws_region) == false ? var.aws_region : trimspace(lookup(local.config_vars, "CONFIG_AWS_REGION", ""))
  shared_credentials_file = contains(["REPLACE_ME", ""], var.shared_credentials_file) == false ? var.shared_credentials_file :trimspace(lookup(local.config_vars, "CONFIG_SHARED_CREDENTIALS_FILE", ""))
  profile = contains(["REPLACE_ME", ""], var.profile) == false ? var.profile : trimspace(lookup(local.config_vars, "CONFIG_PROFILE", ""))
  assume_role {
    role_arn = contains(["REPLACE_ME", ""], var.role_arn) == false ? var.role_arn : trimspace(lookup(local.config_vars, "CONFIG_ROLE_ARN", ""))
  }
}

resource "aws_instance" "dpn-sandbox" {
  ami                    = var.ami
  instance_type          = var.resource_size

  key_name               = trimspace(lookup(local.config_vars, "CONFIG_KEY_NAME", "")) != "" ? trimspace(local.config_vars["CONFIG_KEY_NAME"]) : (
    var.key_name == "REPLACE_ME" ? "" : var.key_name
  )

  vpc_security_group_ids = trimspace(lookup(local.config_vars, "CONFIG_VPC_SECURITY_GROUP_ID", "")) != "" ? [trimspace(local.config_vars["CONFIG_VPC_SECURITY_GROUP_ID"])] : (
    var.vpc_security_group_ids == ["REPLACE_ME"] ? [] : var.vpc_security_group_ids
  )

  subnet_id              = trimspace(lookup(local.config_vars, "CONFIG_SUBNET_ID", "")) != "" ? trimspace(local.config_vars["CONFIG_SUBNET_ID"]) : (
    var.subnet_id == "REPLACE_ME" ? "" : var.subnet_id
  )

  tags = {
    Name    = "dpn-sandbox-${var.resource_name}"
    Creator = var.creator == "REPLACE_ME" ? "" : var.creator
  }

  connection {
    host        = coalesce(self.public_ip, self.private_ip)
    type        = "ssh"
    user        = var.user
    private_key = trimspace(lookup(local.config_vars, "CONFIG_PRIVATE_KEY_PATH", "")) != "" ? file(trimspace(local.config_vars["CONFIG_PRIVATE_KEY_PATH"])) : (
      var.private_key_path == "REPLACE_ME" ? "" : file(var.private_key_path)
    )
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.cwd}/setup.env"
    destination = "~/setup.env"
  }

  provisioner "file" {
    source      = "${path.cwd}/setup.sh"
    destination = "~/setup.sh"
  }

  # testing
  provisioner "file" {
    source      = "${path.cwd}/.require.vars.sh"
    destination = "~/.require.vars.sh"
  }
  provisioner "file" {
    source      = "${path.cwd}/../.setup.pre.sh"
    destination = "~/.setup.pre.sh"
  }
  provisioner "file" {
    source      = "${path.cwd}/../.setup.post.sh"
    destination = "~/.setup.post.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir ~/data",
    ]
  }

  provisioner "file" {
    source = "${path.cwd}/data"
    destination = "~/"
  }

  provisioner "remote-exec" {
    script = "${path.cwd}/setup.sh"
  }
}

output "dns" {
  value = aws_instance.dpn-sandbox.public_ip
}

output "user" {
  value = var.user
}