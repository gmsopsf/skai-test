data "google_client_config" "default" {}

resource "google_compute_instance" "vm_instance" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zones

  // Tags to receive firewall configurations
  tags = var.firewall_target_tags

  boot_disk {
    initialize_params {
      image = var.disk_image
      size  = var.disk_size
    }
  }

  network_interface {
    network = var.network
  }
}

resource "google_compute_instance_group" "ig_replicated_pov" {
  name = var.instance_group_name

  instances = [
    google_compute_instance.vm_instance.id
  ]

  dynamic "named_port" {
    for_each = var.named_ports
    content {
      name = named_port.value.name
      port = named_port.value.port
    }
  }

  zone = var.zones
}

resource "google_compute_health_check" "tcp-health-check" {
  name = "tcp-health-check"

  timeout_sec        = 1
  check_interval_sec = 1

  tcp_health_check {
    port = "30000"
  }
}

resource "google_compute_backend_service" "backend_service_443" {
  name          = "backend-service-443"
  protocol      = "HTTPS"
  port_name     = "https"
  health_checks = [google_compute_health_check.tcp-health-check.self_link]
  backend {
    group = google_compute_instance_group.ig_replicated_pov.self_link
  }
}

resource "google_compute_backend_service" "backend_service_30000" {
  name          = "backend-service-30000"
  protocol      = "HTTPS"
  port_name     = "admin"
  health_checks = [google_compute_health_check.tcp-health-check.self_link]
  backend {
    group = google_compute_instance_group.ig_replicated_pov.self_link
  }
}


### Create manage certificates

resource "google_compute_managed_ssl_certificate" "pr-agent" {
  name = var.pr_agent_certificate_name

  managed {
    domains = [var.pr-agent-domain]
  }
}

resource "google_compute_managed_ssl_certificate" "codium-mate" {
  name = var.codiummate_certificate_name

  managed {
    domains = [var.codium-mate-domain]
  }
}

resource "google_compute_managed_ssl_certificate" "admin" {
  name = var.admin_certificate_name

  managed {
    domains = [var.admin-domain]
  }
}

#Create the loadbalancer with rules to specific backend
resource "google_compute_url_map" "pov-lb" {
  name = var.url-map-name

  default_service = google_compute_backend_service.backend_service_30000.self_link

  host_rule {
    hosts        = [var.pr-agent-domain, var.codium-mate-domain]
    path_matcher = "path-matcher-443"
  }

  path_matcher {
    name            = "path-matcher-443"
    default_service = google_compute_backend_service.backend_service_443.self_link
    path_rule {
      paths   = ["/"]
      service = google_compute_backend_service.backend_service_443.self_link
    }
  }
}
### Assigning the cert with each proxy
resource "google_compute_target_https_proxy" "target-apps" {
  name    = "target-apps"
  url_map = google_compute_url_map.pov-lb.self_link
  ssl_certificates = [
    google_compute_managed_ssl_certificate.pr-agent.self_link,
    google_compute_managed_ssl_certificate.codium-mate.self_link
  ]
}

resource "google_compute_target_https_proxy" "target-admin" {
  name             = "target-admin"
  url_map          = google_compute_url_map.pov-lb.self_link
  ssl_certificates = [google_compute_managed_ssl_certificate.admin.self_link]
}

#creating and reserving IP address for load balancing 
resource "google_compute_global_address" "lb_ip_app" {
  name = var.lb-ip-app
}
resource "google_compute_global_address" "lb_ip_app_admin" {
  name = var.lb-ip-admin
}


#Creating Forward rules
resource "google_compute_global_forwarding_rule" "forwarding_rule_domain_app" {
  name       = "forwarding-rule-domain-apps"
  ip_address = google_compute_global_address.lb_ip_app.address
  target     = google_compute_target_https_proxy.target-apps.self_link
  port_range = "443"
}

resource "google_compute_global_forwarding_rule" "forwarding_rule_domain_admin" {
  name       = "forwarding-rule-domain-admin"
  ip_address = google_compute_global_address.lb_ip_app_admin.address
  target     = google_compute_target_https_proxy.target-admin.self_link
  port_range = "443"
}

### creating the dns for each frontend IP

data "google_dns_managed_zone" "managed_zone" {
  name    = var.managed_dns_zone
  project = var.project_id
}

resource "google_dns_record_set" "dns_record_domain_admin" {
  name         = "${var.admin-domain}."
  type         = "A"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.managed_zone.name
  rrdatas      = [google_compute_global_address.lb_ip_app_admin.address]
}

resource "google_dns_record_set" "dns_record_domain_codium_mate" {
  name         = "${var.codium-mate-domain}."
  type         = "A"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.managed_zone.name
  rrdatas      = [google_compute_global_address.lb_ip_app.address]
}

resource "google_dns_record_set" "dns_record_pr_agent" {
  name         = "${var.pr-agent-domain}."
  type         = "A"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.managed_zone.name
  rrdatas      = [google_compute_global_address.lb_ip_app.address]
}
