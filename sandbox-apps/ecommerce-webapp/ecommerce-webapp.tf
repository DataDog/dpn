
# Unless explicitly stated otherwise all files in this repository are licensed under the Apache 2.0 License.
# This product includes software developed at Datadog (https://www.datadoghq.com/). Copyright 2020 Datadog, Inc.

module "sandbox-apps" {
  resource_name = "ecommerce-webapp"
  source = "../_terraform/"
  resource_size = "t2.medium" # only change for unusually large/small projects. bigger == $$$
}

output "entry" {
  value = "${module.sandbox-apps.user}@${module.sandbox-apps.dns}"
}
