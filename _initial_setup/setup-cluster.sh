#!/bin/sh
# k3s install now lives in machine-setup
# setup/modules/compute/install-k3s.sh.
# The procedure is homelab docs/k3s-ha.md.

# MetalLB v0.16.0, then manifests/01_infrastructure/metallb/pool.yml.
# SMB CSI v1.20.3, then manifests/01_infrastructure/smb/volumes.yml.
# Apply the rest of manifests/ only after those two are Ready.
# Do not apply the later/ directory.
