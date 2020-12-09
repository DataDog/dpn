
# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

resource "tls_private_key" "dpn-key" {
  algorithm = "RSA"
  rsa_bits  = 4096

}

resource "null_resource" "configfile_manager_keypair" {

  triggers = {
    my_os_is_windows = var.my_os_is_windows
  }

  provisioner "local-exec" {
    interpreter = var.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = (var.my_os_is_windows
      ? <<EOT
        Add-Content -Value '${tls_private_key.dpn-key.private_key_pem}' -Path $home\\.ssh\\dpn-sandbox.pem
        Add-Content -Value '${tls_private_key.dpn-key.public_key_openssh}' -Path $home\\.ssh\\dpn-sandbox.pub
        clear
        Write-Host -Value "created private key at $home\.ssh\dpn-sandbox.pem and public key openssh at $home\.ssh\dpn-sandbox.pub"
        Add-Content -Value "CONFIG_PRIVATE_KEY_PATH=$home\.ssh\dpn-sandbox.pem" -Path ${path.cwd}\\configured.tfvars
        Add-Content -Value 'CONFIG_KEY_NAME=${var.creator}-dpn-sandbox-key' -Path ${path.cwd}\\configured.tfvars
        EOT
      : <<EOT
        echo '${tls_private_key.dpn-key.private_key_pem}' > ~/.ssh/dpn-sandbox.pem
        echo '${tls_private_key.dpn-key.public_key_openssh}' > ~/.ssh/dpn-sandbox.pub
        tput reset
        echo 'created private key at ~/.ssh/dpn-sandbox.pem and public key openssh at ~/.ssh/dpn-sandbox.pub'
        echo '\nCONFIG_PRIVATE_KEY_PATH=~/.ssh/dpn-sandbox.pem' >> ${path.cwd}/configured.tfvars
        echo 'CONFIG_KEY_NAME=${var.creator}-dpn-sandbox-key' >> ${path.cwd}/configured.tfvars
        chmod 400 ~/.ssh/dpn-sandbox.pem
        EOT
    )
  }

  provisioner "local-exec" {
    when    = destroy
    interpreter = self.triggers.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = (self.triggers.my_os_is_windows
      ? <<EOT
        Remove-Item -Path $home\\.ssh\\dpn-sandbox.pem -Force
        Remove-Item -Path $home\\.ssh\\dpn-sandbox.pub -Force
        Write-Host -Value "deleted private key at $home\.ssh\dpn-sandbox.pem and public key openssh at $home\.ssh\dpn-sandbox.pub"
        EOT
      : <<EOT
        rm ~/.ssh/dpn-sandbox.pem
        rm ~/.ssh/dpn-sandbox.pub
        sed -i '' '/CONFIG_PRIVATE_KEY_PATH/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_KEY_NAME/d' ${path.cwd}/configured.tfvars
        echo 'deleted private key at ~/.ssh/dpn-sandbox.pem and public key openssh at ~/.ssh/dpn-sandbox.pub'
        EOT
    )
  }
}

resource "aws_key_pair" "dpn-key-pair" {
  key_name   = "${var.creator}-dpn-sandbox-key"
  public_key = tls_private_key.dpn-key.public_key_openssh
}
