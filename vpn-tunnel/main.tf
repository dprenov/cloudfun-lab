terraform {

#
# Import the Terraform provider for GCP
#

  required_providers {
    googleproja = {
      source = "hashicorp/google"
      version = "3.5.0"
    }
    googleprojb = {
      source = "hashicorp/google"
      version = "3.5.0"
    }
  }
}

#
# Set up the Terraform provider for GCP Project "org-a"
#

provider "googleproja" {
  credentials = file(var.credentials_file_a)
  project = var.project_a
  region = var.region
  zone = var.zone
}

#
# Set up the Terraform provider for GCP Project "org-b"
#

provider "googleprojb" {
  credentials = file(var.credentials_file_b)
  project = var.project_b
  region = var.region
  zone = var.zone
}

#
# make a random string called 'ipsec_psk' of 20 characters for the VPN setup
# 
# TO DO: should we show this in 'output' along with other info at the end?

resource "random_password" "ipsec_psk" {
  length  = 20
  special = true
  upper   = true
}

#
# Go and pull in the data for the VPC networks in each project, we're going to need to attach to them so we need to know where they are
# Org-A and Org-B environments must be deployed before you can pull in their VPC data and build the tunnel (duh)
#

data "google_compute_network" "vpc-a" {
  provider = googleproja
  name = "vpc-a"
}

data "google_compute_network" "vpc-b" {
  provider = googleprojb
  name = "vpc-b"
}

#
# Reserve a static IP address for each VPN gateway, 1 for each project/VPC
#

resource "google_compute_address" "vpc-a-gw-staticip" {
  provider = googleproja
  name = "vpc-a-gw-staticip"
}

resource "google_compute_address" "vpc-b-gw-staticip" {
  provider = googleprojb
  name = "vpc-b-gw-staticip"
}

#
# Create VPN gateways, attach them to their respective VPCs
#

resource "google_compute_vpn_gateway" "vpc-a-vpn-gateway" {
  provider = googleproja
  name = "vpc-a-vpn-gateway"
  network = data.google_compute_network.vpc-a.id
}

resource "google_compute_vpn_gateway" "vpc-b-vpn-gateway" {
  provider = googleprojb
  name = "vpc-b-vpn-gateway"
  network = data.google_compute_network.vpc-b.id
}

#
# Create forwarding rules to ensure that IPsec traffic gets passed in from the GFE
#

resource "google_compute_forwarding_rule" "proja_fr_esp" {
  provider    = googleproja
  name        = "fr-esp"
  ip_protocol = "ESP"
  ip_address  = google_compute_address.vpc-a-gw-staticip.address
  target      = google_compute_vpn_gateway.vpc-a-vpn-gateway.id
}

resource "google_compute_forwarding_rule" "proja_fr_udp500" {
  provider    = googleproja
  name        = "fr-udp500"
  ip_protocol = "UDP"
  port_range  = "500"
  ip_address  = google_compute_address.vpc-a-gw-staticip.address
  target      = google_compute_vpn_gateway.vpc-a-vpn-gateway.id
}

resource "google_compute_forwarding_rule" "proja_fr_udp4500" {
  provider    = googleproja
  name        = "fr-udp4500"
  ip_protocol = "UDP"
  port_range  = "4500"
  ip_address  = google_compute_address.vpc-a-gw-staticip.address
  target      = google_compute_vpn_gateway.vpc-a-vpn-gateway.id
}

resource "google_compute_forwarding_rule" "projb_fr_esp" {
  provider    = googleprojb
  name        = "fr-esp"
  ip_protocol = "ESP"
  ip_address  = google_compute_address.vpc-b-gw-staticip.address
  target      = google_compute_vpn_gateway.vpc-b-vpn-gateway.id
}

resource "google_compute_forwarding_rule" "projb_fr_udp500" {
  provider    = googleprojb
  name        = "fr-udp500"
  ip_protocol = "UDP"
  port_range  = "500"
  ip_address  = google_compute_address.vpc-b-gw-staticip.address
  target      = google_compute_vpn_gateway.vpc-b-vpn-gateway.id
}

resource "google_compute_forwarding_rule" "projb_fr_udp4500" {
  provider    = googleprojb
  name        = "fr-udp4500"
  ip_protocol = "UDP"
  port_range  = "4500"
  ip_address  = google_compute_address.vpc-b-gw-staticip.address
  target      = google_compute_vpn_gateway.vpc-b-vpn-gateway.id
}


#
# Create VPN tunnel on each side, routing traffic to the other side
#

resource "google_compute_vpn_tunnel" "tunnel_vpca_to_vpcb" {
  provider    = googleproja
  name          = "tunnel_vpca_to_vpcb"
  peer_ip       = google_compute_address.vpc-b-gw-staticip.address
  shared_secret = random_password.ipsec_psk.result

  target_vpn_gateway = google_compute_vpn_gateway.vpc-a-vpn-gateway.id

  depends_on = [
    google_compute_forwarding_rule.proja_fr_esp,
    google_compute_forwarding_rule.proja_fr_udp500,
    google_compute_forwarding_rule.proja_fr_udp4500,
    google_compute_address.vpc-a-gw-staticip,
    google_compute_address.vpc-b-gw-staticip,
  ]
}

resource "google_compute_vpn_tunnel" "tunnel_vpcb_to_vpca" {
  provider    = googleprojb
  name          = "tunnel_vpcb_to_vpca"
  peer_ip       = google_compute_address.vpc-a-gw-staticip.address
  shared_secret = random_password.ipsec_psk.result

  target_vpn_gateway = google_compute_vpn_gateway.vpc-b-vpn-gateway.id

  depends_on = [
    google_compute_forwarding_rule.projb_fr_esp,
    google_compute_forwarding_rule.projb_fr_udp500,
    google_compute_forwarding_rule.projb_fr_udp4500,
    google_compute_address.vpc-a-gw-staticip,
    google_compute_address.vpc-b-gw-staticip,
  ]
}


#
# Add routes to the VPC routers so they know when to use the VPN tunnel
#

resource "google_compute_route" "route_to_vpcb" {
  provider    = googleproja
  name       = "route-to-vpcb"
  network    = data.google_compute_network.vpc-a.name
  dest_range = var.cidr_ba
  priority   = 1000

  next_hop_vpn_tunnel = google_compute_vpn_tunnel.tunnel_vpca_to_vpcb.id
}

resource "google_compute_route" "route_to_vpca" {
  provider    = googleprojb
  name       = "route-to-vpca"
  network    = data.google_compute_network.vpc-b.name
  dest_range = var.cidr_aa
  priority   = 1000

  next_hop_vpn_tunnel = google_compute_vpn_tunnel.tunnel_vpcb_to_vpca.id
}