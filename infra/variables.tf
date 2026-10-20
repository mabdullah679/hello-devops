variable "name_prefix" {
  description = "Prefix on every resource name (the account is shared)."
  type        = string
  default     = "pf-hello-devops"
}

variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "image_tag" {
  description = "Tag of the image in ECR to deploy (the pipeline passes the git sha)."
  type        = string
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "alert_email" {
  description = "Optional. If set, the alarm topic gets an email subscription (must be confirmed by hand)."
  type        = string
  default     = ""
}
