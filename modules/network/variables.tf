variable "name" {
  description = "Names everything (e.g. acme-studio)"
  type        = string
}

variable "cidr" {
  description = "The VPC's range. Must not overlap vpn_client_cidr"
  type        = string
  default     = "10.42.0.0/16"
}

variable "zones" {
  description = "How many availability zones get a public subnet"
  type        = number
  default     = 2
}

variable "zone_names" {
  description = "Exactly which availability zones get a subnet (e.g. those that offer your GPU type: not every zone has every type); empty: the first `zones` of the region's"
  type        = list(string)
  default     = []
}

variable "vpn" {
  description = "Make the S3 interface endpoint and the Client VPN (billed by the hour)"
  type        = bool
  default     = false
}

variable "vpn_client_cidr" {
  description = "Addresses the Client VPN gives its clients: a /22 or larger, outside cidr"
  type        = string
  default     = "10.200.0.0/22"
}

