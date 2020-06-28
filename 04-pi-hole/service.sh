#!/bin/bash
# Never Directly Execute This Script
return

git clone https://github.com/MoJo2600/pihole-kubernetes.git

kubectl apply -f admin-secret.yml
kubectl apply -f persistentvolumeclaim.yml

helm install pihole ~/repos/references/pihole-kubernetes/charts/pihole/ --namespace pi-hole --values values.yml

helm uninstall pihole --namespace pi-hole
