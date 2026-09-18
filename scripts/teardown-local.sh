#!/usr/bin/env bash
# Delete the kind cluster and the local registry (all local data is lost).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kind docker
read -r -p "Delete kind cluster 'cloudforge' and registry 'kind-registry'? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted"; exit 0; }
kind delete cluster --name cloudforge || true
docker rm -f kind-registry 2>/dev/null || true
log "local environment removed"
