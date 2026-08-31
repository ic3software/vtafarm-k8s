moved {
  from = hcloud_network.this
  to   = hcloud_network.this[0]
}

moved {
  from = hcloud_network_subnet.nodes
  to   = hcloud_network_subnet.nodes[0]
}

moved {
  from = hcloud_placement_group.nodes
  to   = hcloud_placement_group.nodes[0]
}

moved {
  from = hcloud_load_balancer.api
  to   = hcloud_load_balancer.api[0]
}

moved {
  from = hcloud_load_balancer_network.api
  to   = hcloud_load_balancer_network.api[0]
}

moved {
  from = hcloud_load_balancer_service.kubernetes_api
  to   = hcloud_load_balancer_service.kubernetes_api[0]
}

moved {
  from = hcloud_load_balancer_service.rke2_supervisor
  to   = hcloud_load_balancer_service.rke2_supervisor[0]
}

moved {
  from = hcloud_load_balancer_service.ingress_http
  to   = hcloud_load_balancer_service.ingress_http[0]
}

moved {
  from = hcloud_load_balancer_service.ingress_https
  to   = hcloud_load_balancer_service.ingress_https[0]
}
