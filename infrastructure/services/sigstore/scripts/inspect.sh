#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
for tool in kind docker kubectl helm cosign mkcert jq openssl curl python3; do
  command -v "$tool" || fail "Missing executable: $tool"
done
kind get clusters | grep -Fx "$cluster"
[[ $(kubectl config current-context) == "$context" ]] || fail "Select $context in $KUBECONFIG"
docker info --format '{{.ServerVersion}}'
helm version --short
cosign version --json | jq -e '.gitVersion == "v3.1.4"'
k version
k get nodes,namespaces,ingressclasses,storageclasses
k get ingress,svc,pvc -A
k get deployments,statefulsets -A
h list -A
for resource in gateways.gateway.networking.k8s.io issuers.cert-manager.io clusterissuers.cert-manager.io; do
  if k api-resources -o name | grep -Fx "$resource" >/dev/null; then k get "$resource" -A; fi
done
docker ps --format '{{.Names}} {{.Image}} {{.Ports}}'
k -n kube-public get configmap local-registry-hosting --ignore-not-found -o yaml
k -n traefik get svc traefik -o json | jq -e 'any(.spec.ports[]; .port == 443 and .nodePort == 30443)'
docker port "$cluster-control-plane" 30443/tcp | grep -Fx '127.0.0.1:443'
k get ingressclass traefik
k get storageclass -o json | jq -e 'any(.items[]; .metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")'
k get --raw /readyz
