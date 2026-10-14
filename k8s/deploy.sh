#!/usr/bin/env bash
# Deploy / tear down Open5GS + OCUDU gNB + Grafana in one go (steps 1-4 and Teardown from README.md).
#
#   ./k8s/deploy.sh up      # install or upgrade everything (safe to re-run)
#   ./k8s/deploy.sh down    # remove everything
#   ./k8s/deploy.sh gnb       # gNB + Grafana only, attached to the Open5GS from open5gs/docker-compose.yml
#   ./k8s/deploy.sh gnb-lite  # gNB only; Grafana/InfluxDB/Telegraf run in docker compose (see README)
#   ./k8s/deploy.sh gnb-o1    # like gnb-lite, plus the O1 sidecars (netconf-server + o1-adapter) in the gNB pod
#
# Uses the current kubectl context. On docker-desktop it also applies the SCTP workaround (README section 2).
set -euo pipefail

K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$K8S_DIR")"
OCUDU_HELM="$ROOT_DIR/ocudu_helm"

OPERATOR_VERSION=1.0.7
GRAFANA_VERSION=2.5.2
# ocudu_helm has no tags; pin a main commit (ocudu-gnb chart 3.12.x).
OCUDU_HELM_REF=47062ad36c6b3588280a7a6ad1783b5ef34f746c

CONTEXT="$(kubectl config current-context)"

log() { printf '\n==> %s\n' "$*"; }

open5gs_up() {
  log "Open5GS operator $OPERATOR_VERSION"
  helm upgrade --install open5gs-operator oci://registry-1.docker.io/gradiantcharts/open5gs-operator \
    --version "$OPERATOR_VERSION" -n open5gs --create-namespace --wait
  kubectl apply -f "$K8S_DIR/open5gs.yaml"

  if [[ "$CONTEXT" == docker-desktop ]]; then
    log "Docker Desktop SCTP workaround"
    # Let the operator create the SCTP Service first, otherwise it recreates it after we delete it.
    echo "waiting for the operator to create svc/open5gs-amf-ngap..."
    for _ in $(seq 120); do
      kubectl -n open5gs get svc open5gs-amf-ngap >/dev/null 2>&1 && break
      sleep 2
    done
    kubectl -n open5gs scale deploy open5gs-operator-controller-manager --replicas=0
    kubectl -n open5gs delete svc open5gs-amf-ngap --ignore-not-found
    kubectl apply -f "$K8S_DIR/amf-ngap-headless.yaml"
    echo "waiting 30 s for kube-proxy to resync..."
    sleep 30
    # Anything that started while Services were broken may be stuck in CrashLoopBackOff.
    kubectl -n open5gs rollout restart deploy open5gs-udr open5gs-pcf
  else
    kubectl apply -f "$K8S_DIR/amf-ngap-headless.yaml"
  fi

  log "Waiting for Open5GS deployments"
  kubectl -n open5gs wait --for=condition=Available deploy --all --timeout=10m
}

# Arguments: values files, relative to k8s/ or absolute.
gnb_up() {
  local values_args=() v
  if [[ ! -d "$OCUDU_HELM" ]]; then
    log "Cloning ocudu_helm (main, core.autocrlf=false)"
    git clone -c core.autocrlf=false https://gitlab.com/ocudu/ocudu_elements/ocudu_helm.git "$OCUDU_HELM"
  fi
  if [[ "$(git -C "$OCUDU_HELM" rev-parse HEAD)" != "$OCUDU_HELM_REF" ]]; then
    log "Checking out ocudu_helm $OCUDU_HELM_REF"
    git -C "$OCUDU_HELM" fetch origin
    git -C "$OCUDU_HELM" checkout --detach "$OCUDU_HELM_REF"
  fi

  for v in "$@"; do
    [[ "$v" == /* ]] || v="$K8S_DIR/$v"
    values_args+=(-f "$v")
  done

  log "OCUDU gNB"
  kubectl create namespace ran --dry-run=client -o yaml | kubectl apply -f -
  kubectl label ns ran pod-security.kubernetes.io/enforce=privileged --overwrite
  helm upgrade --install gnb "$OCUDU_HELM/charts/ocudu-gnb" -n ran \
    "${values_args[@]}" --wait --timeout 10m
}

grafana_up() {
  log "Grafana + InfluxDB3 + Telegraf $GRAFANA_VERSION"
  helm upgrade --install grafana oci://registry.gitlab.com/ocudu/ocudu_elements/ocudu_helm/grafana-ocudu \
    --version "$GRAFANA_VERSION" -n monitoring --create-namespace \
    -f "$K8S_DIR/grafana-ocudu-values.yaml" --wait --timeout 10m
}

up() {
  echo "kubectl context: $CONTEXT"
  open5gs_up
  gnb_up ocudu-gnb-values.yaml
  grafana_up
  log "Done"
  echo "gNB logs: kubectl -n ran logs -f deploy/gnb-ocudu-gnb"
  echo "Grafana:  http://localhost:30001 (admin / admin1234)"
}

require_compose_core() {
  if ! docker inspect -f '{{.State.Running}}' open5gs_5gc 2>/dev/null | grep -q true; then
    echo "open5gs_5gc is not running; start it first:" >&2
    echo "  docker compose -f open5gs/docker-compose.yml up -d" >&2
    exit 1
  fi
}

gnb_compose() {
  echo "kubectl context: $CONTEXT"
  require_compose_core
  gnb_up ocudu-gnb-compose-values.yaml
  grafana_up
  log "Done"
  echo "gNB logs: kubectl -n ran logs -f deploy/gnb-ocudu-gnb"
  echo "Grafana:  http://localhost:30001 (admin / admin1234)"
}

gnb_lite() {
  echo "kubectl context: $CONTEXT"
  require_compose_core
  gnb_up ocudu-gnb-compose-values.yaml
  log "Done"
  echo "gNB logs: kubectl -n ran logs -f deploy/gnb-ocudu-gnb"
  echo "Metrics:  docker compose -f ocudu/docker/docker-compose.ui.yml -f k8s/compose-ui-gnb-k8s.yml up -d"
  echo "          Grafana at http://localhost:3300"
}

gnb_o1() {
  echo "kubectl context: $CONTEXT"
  require_compose_core
  # The chart's values-o1.yaml enables the sidecars; ours swaps in the ru_dummy/test_ue NETCONF config.
  gnb_up "$OCUDU_HELM/charts/ocudu-gnb/values-o1.yaml" ocudu-gnb-o1-values.yaml
  log "Done"
  echo "gNB logs:   kubectl -n ran logs -f deploy/gnb-ocudu-gnb -c ocudu-gnb"
  echo "O1 adapter: kubectl -n ran logs -f deploy/gnb-ocudu-gnb -c ocudu-o1-adapter"
  echo "NETCONF:    localhost:30830 (root / root)"
}

down() {
  echo "kubectl context: $CONTEXT"
  helm uninstall grafana -n monitoring --ignore-not-found
  helm uninstall gnb -n ran --ignore-not-found

  # The Open5GS CR is cleaned up by the operator, so it must be running.
  if kubectl -n open5gs get deploy open5gs-operator-controller-manager >/dev/null 2>&1; then
    kubectl -n open5gs scale deploy open5gs-operator-controller-manager --replicas=1
    kubectl -n open5gs rollout status deploy open5gs-operator-controller-manager --timeout=2m
    kubectl delete -f "$K8S_DIR/open5gs.yaml" --ignore-not-found --wait --timeout=3m
  fi
  helm uninstall open5gs-operator -n open5gs --ignore-not-found
  kubectl delete -f "$K8S_DIR/amf-ngap-headless.yaml" --ignore-not-found
  kubectl delete ns ran open5gs monitoring --ignore-not-found
  log "Done"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  gnb) gnb_compose ;;
  gnb-lite) gnb_lite ;;
  gnb-o1) gnb_o1 ;;
  *) echo "usage: $0 up|down|gnb|gnb-lite|gnb-o1" >&2; exit 1 ;;
esac
