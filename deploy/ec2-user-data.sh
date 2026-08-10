#!/bin/bash
# EC2 user-data for Amazon Linux 2023 — installs Docker so the archive
# container can run. Paste this into the launch wizard under
# "Advanced details -> User data"; it runs once at first boot.
set -euxo pipefail

dnf update -y
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user   # so `docker` works without sudo after re-login

# docker compose plugin (optional; the test below uses plain `docker run`)
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m) \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo "Docker ready. Load/pull the tr-archive image, then:"
echo "  docker run -d --name tr-archive --restart unless-stopped -p 80:80 tr-archive:poc"
