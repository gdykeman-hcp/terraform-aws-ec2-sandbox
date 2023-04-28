#!/bin/sh

## Get instance IP from cloud-init (replace with VM IP when appropriate)
INSTANCE_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)

## Install repos and packages
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -

apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"

apt update && apt install -y unzip consul jq docker.io

cat <<EOT > /etc/consul.d/consul.hcl
datacenter = "dc2"
data_dir = "/opt/consul"
log_level = "INFO"
server = true
bootstrap_expect = 1
advertise_addr = "${INSTANCE_IP}"
bind_addr = "{{ GetDefaultInterfaces | exclude \"type\" \"IPv6\" | attr \"address\" }}"
client_addr = "0.0.0.0"
ui = true
ports {
  serf_wan = -1
  grpc = 8502
}

retry_join = [ "provider=aws tag_key=consul tag_value=server" ]

connect {
  enabled = true
}

dns_config {
    allow_stale = true
    node_ttl = "2s"
    service_ttl {
	    "*" = "2s"
    }
    use_cache = true
    cache_max_age = "2s"
}

telemetry {
  prometheus_retention_time = "10m"
  disable_hostname = true
}

acl {
  enabled = true
  default_policy = "deny"
  enable_token_persistence = true
  tokens {
    initial_management = "root"
    agent = "root"
  }
}
EOT



systemctl daemon-reload
systemctl enable consul --now

sleep 15

export CONSUL_HTTP_TOKEN=root
echo CONSUL_HTTP_TOKEN=root >> /etc/environment


## Enable peering through mesh gateways
cat <<EOT > /root/mesh.hcl
Kind = "mesh"
Peering {
  PeerThroughMeshGateways = true
}
EOT
consul config write /root/mesh.hcl


## Install Envoy
wget wget https://github.com/envoyproxy/envoy/releases/download/v1.24.1/envoy-1.24.1-linux-x86_64
mv envoy-1.24.1-linux-x86_64 /usr/local/bin/envoy
chmod +x /usr/local/bin/envoy

cat <<EOT > /etc/systemd/system/mesh-gateway.service
[Unit]
Description=Consul Mesh Gateway
After=syslog.target network.target

[Service]
Environment=CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN}
ExecStart=/usr/bin/consul connect envoy -mesh-gateway -register -address ${INSTANCE_IP}:8443 -wan-address ${INSTANCE_IP}:8443
ExecStop=/bin/sleep 5
Restart=always

[Install]
WantedBy=multi-user.target
EOT

## Deploy the gateways
cat <<EOT > /etc/systemd/system/ingress-gateway.service
[Unit]
Description=Consul Ingress Gateway
After=syslog.target network.target

[Service]
Environment=CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN}
ExecStart=/usr/bin/consul connect envoy -gateway ingress -register -admin-bind 127.0.0.1:19001
ExecStop=/bin/sleep 5
Restart=always

[Install]
WantedBy=multi-user.target
EOT

cat <<EOT > /etc/systemd/system/terminating-gateway.service
[Unit]
Description=Consul Terminating Gateway
After=syslog.target network.target

[Service]
Environment=CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN}
ExecStart=/usr/bin/consul connect envoy -gateway terminating -register -admin-bind 127.0.0.1:19002 -address ${INSTANCE_IP}:8444
ExecStop=/bin/sleep 5
Restart=always

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable terminating-gateway --now
systemctl enable ingress-gateway --now
systemctl enable mesh-gateway --now



## Get a fake service going
mkdir /opt/fake-service
wget https://github.com/nicholasjackson/fake-service/releases/download/v0.24.2/fake_service_linux_amd64.zip
unzip -d /opt/fake-service/ fake_service_linux_amd64.zip
chmod +x /opt/fake-service/fake-service 

cat <<EOT > /etc/systemd/system/spectrum-guard.service
[Unit]
Description=Fake Service
After=syslog.target network.target

[Service]
Environment=NAME="Legacy Service"
Environment=MESSAGE="I'm running on a VM"
ExecStart=/opt/fake-service/fake-service
ExecStop=/bin/sleep 5
Restart=always

[Install]
WantedBy=multi-user.target
EOT

cat <<EOT > /etc/consul.d/spectrum-guard.hcl
service {
  name = "spectrum-guard"
  port = 9090
  tags = ["vm", "spectrum-guard"]

  checks = [
    {
      name = "HTTP API on port 9090"
      http = "http://127.0.0.1:9090/health"
      interval = "10s"
      timeout = "5s"
    }
  ]

  # connect = {
  #   sidecar_service = {}
  # }
  token = "${CONSUL_HTTP_TOKEN}"
}
EOT

cat <<EOT > /etc/systemd/system/spectrum-guard-sidecar.service
[Unit]
Description=Consul Envoy
After=syslog.target network.target

[Service]
Environment=CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN}
ExecStart=/usr/bin/consul connect envoy -sidecar-for spectrum-guard -admin-bind 127.0.0.1:19003
ExecStop=/bin/sleep 5
Restart=always

[Install]
WantedBy=multi-user.target
EOT

consul reload
systemctl daemon-reload
systemctl enable spectrum-guard --now
#systemctl enable spectrum-guard-sidecar --now


cat <<EOT > /root/exported-services.hcl
Kind = "exported-services"
Name = "default"
Services = [
  {
    Name = "spectrum-guard"
    Consumers = [
      {
        Peer = "dc1"
      }
    ]
  }
]
EOT

consul config write /root/exported-services.hcl

cat <<EOT > /root/terminating.hcl
Kind = "terminating-gateway"
Name = "terminating-gateway"

Services = [
  {
    Name = "spectrum-guard"
  }
]
EOT

consul config write /root/terminating.hcl

cat <<EOT > /root/ingress.hcl
Kind = "ingress-gateway"
Name = "ingress-gateway"

Listeners = [
  {
    Port     = 3456
    Protocol = "tcp"
    Services = [
      {
        Name = "spectrum-guard"
      }
    ]
  }
]
EOT

consul config write /root/ingress.hcl

cat <<EOT > /root/intention.hcl
Kind = "service-intentions"
Name = "spectrum-guard"
Sources = [
  {
    Name   = "ingress-gateway"
    Action = "allow"
  },
  {
    Name   = "ingress-gateway"
    Peer   = "dc1"
    Action = "allow"
  }
]
EOT

consul config write /root/intention.hcl