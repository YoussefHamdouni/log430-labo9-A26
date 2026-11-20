#!/usr/bin/env bash
# Labo 09 – Activité 7 : déploiement sur la grappe Kubernetes de l'ÉTS
#
# À lancer à la main, après un pipeline CI/CD réussi (.github/workflows/ci-cd.yml),
# depuis une machine connectée au VPN de l'ÉTS et avec kubectl configuré (voir kubernetes.md du labo 05).
# Les runners de GitHub sont hors du réseau de l'ÉTS : ils ne peuvent pas lancer ce déploiement eux-mêmes.
#
# Utilisation : bash k8s/deploy.sh
set -euo pipefail

cd "$(dirname "$0")/.."
MANIFEST=k8s/cockroachdb.yml

echo "== 1. Vérifier l'accès à la grappe (VPN + kubectl)"
if ! kubectl auth whoami > /dev/null 2>&1; then
  echo "Grappe injoignable : connectez-vous au VPN de l'ÉTS et vérifiez votre contexte kubectl." >&2
  exit 1
fi
kubectl config view --minify -o jsonpath='Contexte : {.contexts[0].name}, espace de noms : {.contexts[0].context.namespace}{"\n"}'

echo "== 2. Appliquer $MANIFEST"
kubectl apply -f "$MANIFEST"

echo "== 3. Attendre les 3 pods du StatefulSet"
kubectl rollout status statefulset/cockroachdb --timeout=300s

echo "== 4. Initialiser la grappe CockroachDB (seulement au premier déploiement)"
if output=$(kubectl exec cockroachdb-0 -- /cockroach/cockroach init --insecure 2>&1); then
  echo "$output"
elif echo "$output" | grep -q "already been initialized"; then
  echo "Grappe déjà initialisée"
else
  echo "$output" >&2
  exit 1
fi

echo "== 5. Vérifier les nœuds"
kubectl exec cockroachdb-0 -- /cockroach/cockroach node status --insecure
kubectl get pods,pvc,svc -l app=cockroachdb
