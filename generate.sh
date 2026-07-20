#!/usr/bin/env bash
# Renders the argo_ci templates for one project into a target directory.
# See params.example.env for the parameter reference.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: generate.sh --params <params.env> --out <output-dir> [--golangci-out <path>]

  --params <file>        Env file defining the project's parameters
                          (see params.example.env in this directory).
  --out <dir>             Directory to render ci/*.yaml and ci/events/*.yaml
                          into (typically <project>/ci).
  --golangci-out <path>  Where to write the rendered .golangci.yml
                          (default: <output-dir>/../.golangci.yml).
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

PARAMS_FILE=""
OUT_DIR=""
GOLANGCI_OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --params) PARAMS_FILE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --golangci-out) GOLANGCI_OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$PARAMS_FILE" ] || { echo "Error: --params is required" >&2; usage; exit 1; }
[ -n "$OUT_DIR" ] || { echo "Error: --out is required" >&2; usage; exit 1; }
[ -f "$PARAMS_FILE" ] || { echo "Error: params file not found: $PARAMS_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$PARAMS_FILE"

: "${GIT_BRANCH:=main}"
: "${NAMESPACE:=argo}"
: "${EVENTS_NAMESPACE:=argo-events}"
# Note: uses = not := so an explicitly-empty BUILD_TAG (disable tagged
# tests) is preserved - := would treat empty the same as unset.
: "${BUILD_TAG=test}"
: "${COMMIT_STATUS_CONTEXT:=argo-ci}"
GOLANGCI_OUT="${GOLANGCI_OUT:-$OUT_DIR/../.golangci.yml}"

required=(PROJECT_NAME GITEA_HOST GITEA_IP GITEA_OWNER GITEA_REPO GO_IMAGE COVERAGE_THRESHOLD)
missing=()
for var in "${required[@]}"; do
  if [ -z "${!var:-}" ]; then
    missing+=("$var")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Error: missing required parameters: ${missing[*]}" >&2
  exit 1
fi

if [ -n "$BUILD_TAG" ]; then
  TAGGED_TEST_CMD="go test -tags $BUILD_TAG ./... -coverprofile=coverage.out"
  # Trailing space is deliberate: it's the separator before the "./..."
  # that immediately follows the placeholder in the template. Left out
  # entirely (empty BUILD_TAG) so no double space is left behind.
  LINT_BUILD_TAGS_FLAG="--build-tags $BUILD_TAG "
else
  TAGGED_TEST_CMD="go test ./... -coverprofile=coverage.out"
  LINT_BUILD_TAGS_FLAG=""
fi

mkdir -p "$OUT_DIR/events"

render() {
  local src="$1" dst="$2"
  sed \
    -e "s|__ARGOCI_PROJECT_NAME__|${PROJECT_NAME}|g" \
    -e "s|__ARGOCI_GITEA_HOST__|${GITEA_HOST}|g" \
    -e "s|__ARGOCI_GITEA_IP__|${GITEA_IP}|g" \
    -e "s|__ARGOCI_GITEA_OWNER__|${GITEA_OWNER}|g" \
    -e "s|__ARGOCI_GITEA_REPO__|${GITEA_REPO}|g" \
    -e "s|__ARGOCI_GIT_BRANCH__|${GIT_BRANCH}|g" \
    -e "s|__ARGOCI_GO_IMAGE__|${GO_IMAGE}|g" \
    -e "s|__ARGOCI_COVERAGE_THRESHOLD__|${COVERAGE_THRESHOLD}|g" \
    -e "s|__ARGOCI_NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__ARGOCI_EVENTS_NAMESPACE__|${EVENTS_NAMESPACE}|g" \
    -e "s|__ARGOCI_COMMIT_STATUS_CONTEXT__|${COMMIT_STATUS_CONTEXT}|g" \
    -e "s|__ARGOCI_TAGGED_TEST_CMD__|${TAGGED_TEST_CMD}|g" \
    -e "s|__ARGOCI_LINT_BUILD_TAGS_FLAG__|${LINT_BUILD_TAGS_FLAG}|g" \
    "$src" > "$dst"
}

render "$TEMPLATES_DIR/workflow-template.yaml.tmpl" "$OUT_DIR/workflow-template.yaml"
render "$TEMPLATES_DIR/rbac.yaml.tmpl" "$OUT_DIR/rbac.yaml"
render "$TEMPLATES_DIR/events/eventsource.yaml.tmpl" "$OUT_DIR/events/eventsource.yaml"
render "$TEMPLATES_DIR/events/sensor.yaml.tmpl" "$OUT_DIR/events/sensor.yaml"
render "$TEMPLATES_DIR/events/sensor-rbac.yaml.tmpl" "$OUT_DIR/events/sensor-rbac.yaml"
render "$TEMPLATES_DIR/events/networkpolicy.yaml.tmpl" "$OUT_DIR/events/networkpolicy.yaml"
render "$TEMPLATES_DIR/events/eventbus.yaml.tmpl" "$OUT_DIR/events/eventbus.yaml"

mkdir -p "$(dirname "$GOLANGCI_OUT")"
render "$TEMPLATES_DIR/golangci.yml.tmpl" "$GOLANGCI_OUT"

echo "Rendered CI manifests into: $OUT_DIR"
echo "Rendered lint config into:  $GOLANGCI_OUT"
