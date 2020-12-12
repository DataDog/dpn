
# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

resource "aws_vpc" "dpn" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  tags = {
    Name = "dpn"
  }
}

resource "aws_subnet" "dpn" {
  vpc_id                  = aws_vpc.dpn.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = "true"
  tags                    = {
    Name = "dpn"
  }
}

resource "aws_internet_gateway" "dpn" {
  vpc_id = aws_vpc.dpn.id

  tags = {
    Name = "dpn"
  }
}

resource "aws_route_table" "dpn" {
  vpc_id = aws_vpc.dpn.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dpn.id
  }

  tags = {
    Name = "dpn"
  }
}

resource "aws_route_table_association" "dpn" {
  subnet_id      = aws_subnet.dpn.id
  route_table_id = aws_route_table.dpn.id
}

resource "aws_security_group" "dpn" {
  name        = "dpn"
  description = "Manage in/egress access for DPN instances"
  vpc_id      = aws_vpc.dpn.id

  ingress {
    description = "TLS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.dpn.cidr_block]
  }

  ingress {
    description = "allow ssh from listed IPs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [
      for ip in var.access_ips:
      ip
    ]
  }

  ingress {
    description = "allow https from listed IPs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [
      for ip in var.access_ips:
      ip
    ]
  }

  ingress {
    description = "allow 8000 from listed IPs"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [
      for ip in var.access_ips:
      ip
    ]
  }

  ingress {
    description = "allow 8080 from listed IPs"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [
      for ip in var.access_ips:
      ip
    ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "dpn"
  }

}

resource "null_resource" "configfile_manager_vpc" {

  triggers = {
    my_os_is_windows = var.my_os_is_windows
  }

  provisioner "local-exec" {
    interpreter = var.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = (var.my_os_is_windows
      ? <<EOT
        Add-Content -Value 'CONFIG_VPC_SECURITY_GROUP_ID=${aws_security_group.dpn.id}' -Path ${path.cwd}\\configured.tfvars
        Add-Content -Value 'CONFIG_SUBNET_ID=${aws_subnet.dpn.id}' -Path ${path.cwd}\\configured.tfvars
        EOT
      : <<EOT
        echo 'CONFIG_VPC_SECURITY_GROUP_ID=${aws_security_group.dpn.id}' >> ${path.cwd}/configured.tfvars
        echo 'CONFIG_SUBNET_ID=${aws_subnet.dpn.id}' >> ${path.cwd}/configured.tfvars
        EOT
    )
  }

  provisioner "local-exec" {
    when    = destroy
    interpreter = self.triggers.my_os_is_windows ? ["powershell", "-Command"] : ["/bin/bash", "-c"]
    command = (self.triggers.my_os_is_windows
      ? <<EOT
        Write-Host -Value 'deleted configs'
        EOT
      : <<EOT
        sed -i '' '/CONFIG_VPC_SECURITY_GROUP_ID/d' ${path.cwd}/configured.tfvars
        sed -i '' '/CONFIG_SUBNET_ID/d' ${path.cwd}/configured.tfvars
        EOT
    )
  }

}