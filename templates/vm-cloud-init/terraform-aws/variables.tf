variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "site_domain" {
  description = "The public site's domain (a DNS A record must point at the output public_ip)"
  type        = string
}

variable "admin_domain" {
  description = "The admin's domain (also pointed at public_ip)"
  type        = string
}

variable "ssh_cidr" {
  description = "Who may reach SSH (22). Your own address, e.g. 203.0.113.7/32. There is no default on purpose."
  type        = string
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair; empty = no SSH key (use Session Manager or add one)"
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "2 vCPU / 4 GB is comfortable; t3.small (2 GB) works with the swap file the bootstrap adds"
  type        = string
  default     = "t3.medium"
}

variable "disk_gb" {
  description = "Root volume size (images, database, uploads and local backups live on it; consider a separate data volume for a large media library)"
  type        = number
  default     = 40
}
