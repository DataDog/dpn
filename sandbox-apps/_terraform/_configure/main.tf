
# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

provider "aws" {
  region = var.aws_region == "REPLACE_ME" ? "" : var.aws_region
  shared_credentials_file = var.shared_credentials_file == "REPLACE_ME" ? "" : var.shared_credentials_file
  profile = var.profile == "REPLACE_ME" ? "" : var.profile
  assume_role {
    role_arn = var.role_arn == "REPLACE_ME" ? "" : var.role_arn
  }
}

resource "null_resource" "configfile_manager" {

  triggers = {
    my_os_is_windows = var.my_os_is_windows
  }

  provisioner "local-exec" {
    interpreter = var.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = contains(["REPLACE_ME", ""], var.aws_region) ? "echo ''" : (
      var.my_os_is_windows 
        ? "Add-Content -Value '\nCONFIG_AWS_REGION=${var.aws_region}' -Path ${path.cwd}\\configured.tfvars"
        : "echo 'CONFIG_AWS_REGION=${var.aws_region}' >> ${path.cwd}/configured.tfvars"
    )
  }
  provisioner "local-exec" {
    interpreter = var.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = contains(["REPLACE_ME", ""], var.aws_region) ? "echo ''" : (
    var.my_os_is_windows 
        ? "Add-Content -Value '\nCONFIG_CREATOR=${var.creator}' -Path ${path.cwd}\\configured.tfvars"
        : "echo 'CONFIG_CREATOR=${var.creator}' >> ${path.cwd}/configured.tfvars"
    )
  }
  provisioner "local-exec" {
    interpreter = var.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = contains(["REPLACE_ME", ""], var.shared_credentials_file) ? "echo ''" : (
      var.my_os_is_windows 
        ? "Add-Content -Value 'CONFIG_SHARED_CREDENTIALS_FILE=${var.shared_credentials_file}' -Path ${path.cwd}\\configured.tfvars"
        : "echo 'CONFIG_SHARED_CREDENTIALS_FILE=${var.shared_credentials_file}' >> ${path.cwd}/configured.tfvars"
    )
  }
  provisioner "local-exec" {
    interpreter = var.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = contains(["REPLACE_ME", ""], var.profile) ? "echo ''" : (
      var.my_os_is_windows 
        ? "Add-Content -Value 'CONFIG_PROFILE=${var.profile}' -Path ${path.cwd}\\configured.tfvars"
        : "echo 'CONFIG_PROFILE=${var.profile}' >> ${path.cwd}/configured.tfvars"
    )
  }
  provisioner "local-exec" {
    interpreter = var.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = contains(["REPLACE_ME", ""], var.role_arn) ? "echo ''" : (
      var.my_os_is_windows 
        ? "Add-Content -Value 'CONFIG_ROLE_ARN=${var.role_arn}' -Path ${path.cwd}\\configured.tfvars"
        : "echo 'CONFIG_ROLE_ARN=${var.role_arn}' >> ${path.cwd}/configured.tfvars"
    )
  }
  provisioner "local-exec" {
    when    = destroy
    interpreter = self.triggers.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = (self.triggers.my_os_is_windows
      ? <<EOT
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_AWS_REGION"} | Set-Content ${path.cwd}\\configured.tfvars
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_CREATOR"} | Set-Content ${path.cwd}\\configured.tfvars
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_SHARED_CREDENTIALS_FILE"} | Set-Content ${path.cwd}\\configured.tfvars
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_PROFILE"} | Set-Content ${path.cwd}\\configured.tfvars
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_ROLE_ARN"} | Set-Content ${path.cwd}\\configured.tfvars
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_PRIVATE_KEY_PATH"} | Set-Content ${path.cwd}\\configured.tfvars
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_KEY_NAME"} | Set-Content ${path.cwd}\\configured.tfvars
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_VPC_SECURITY_GROUP_ID"} | Set-Content ${path.cwd}\\configured.tfvars
        (Get-Content ${path.cwd}\\configured.tfvars) | Where-Object {$_ -notmatch "CONFIG_SUBNET_ID"} | Set-Content ${path.cwd}\\configured.tfvars
        (gc ${path.cwd}\\configured.tfvars) | ? {$_.trim() -ne "" } | set-content ${path.cwd}\\configured.tfvars
        EOT
      : <<EOT
        sed -i '' '/CONFIG_AWS_REGION/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_CREATOR/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_SHARED_CREDENTIALS_FILE/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_PROFILE/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_ROLE_ARN/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_PRIVATE_KEY_PATH/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_KEY_NAME/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_VPC_SECURITY_GROUP_ID/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_SUBNET_ID/d' ${path.cwd}/configured.tfvars
        sed -i '' '/^$/d' ${path.cwd}/configured.tfvars
        EOT
    )
  }
}