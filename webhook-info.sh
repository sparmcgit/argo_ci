#!/usr/bin/env bash
# Exposes a project's gitea EventSource Service as NodePort (if not already)
# and prints the Gitea webhook settings to configure from that.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: webhook-info.sh <project-name> [events-namespace]

  project-name        PROJECT_NAME used when this project's manifests were
                       rendered - the Service is named <project-name>-gitea-eventsource-svc.
  events-namespace     defaults to argo-events

Requires ci/events/eventsource.yaml for this project to already be applied.
EOF
}

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 0
fi

PROJECT_NAME="$1"
EVENTS_NAMESPACE="${2:-argo-events}"
SVC="${PROJECT_NAME}-gitea-eventsource-svc"

echo "Patching $SVC (-n $EVENTS_NAMESPACE) to NodePort..." >&2
kubectl patch svc "$SVC" -n "$EVENTS_NAMESPACE" -p '{"spec":{"type":"NodePort"}}' >/dev/null

NODE_PORT=$(kubectl get svc "$SVC" -n "$EVENTS_NAMESPACE" \
  -o jsonpath='{.spec.ports[?(@.port==12000)].nodePort}')
if [ -z "$NODE_PORT" ]; then
  echo "Error: could not read the NodePort for $SVC - check it exists:" >&2
  echo "  kubectl get svc $SVC -n $EVENTS_NAMESPACE" >&2
  exit 1
fi

NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
if [ -z "$NODE_IP" ]; then
  NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
fi
if [ -z "$NODE_IP" ]; then
  echo "Warning: could not determine a node IP automatically - run" >&2
  echo "  kubectl get nodes -o wide" >&2
  echo "and substitute one below yourself." >&2
  NODE_IP="<node-ip>"
fi

cat <<EOF

Gitea webhook settings for '$PROJECT_NAME' (repo Settings -> Webhooks -> Add Webhook -> Gitea):
  Target URL:    http://${NODE_IP}:${NODE_PORT}/push
  HTTP Method:   POST
  Content Type:  application/json
  Trigger On:    Push events

If delivery fails with "webhook can only call allowed HTTP servers", that's
Gitea's webhook.ALLOWED_HOST_LIST SSRF guard - see TROUBLESHOOTING.md #5.
EOF
