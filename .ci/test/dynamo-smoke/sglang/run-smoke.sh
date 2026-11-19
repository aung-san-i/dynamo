#!/usr/bin/env bash
# SGLang smoke tests for one device: the engine alone, then Dynamo + the engine.
#
#   run-smoke.sh <xpu|nvidia> <image> <resource_claim_template> <node_label> <log_dir>
#
#   engine  <device>-gpu-pod.yaml          sglang.launch_server on :8000
#   dynamo  <device>-gpu-dynamo-pod.yaml   NATS + etcd + dynamo.sglang + dynamo.frontend on :8000
#
# Each pod must answer /health, list a model on /v1/models and return HTTP 200 for
# one chat completion. Both pods always run (an engine failure does not skip the
# Dynamo pod, so one run shows both results); the exit code is non-zero if
# either failed. Pod logs, describe and the response bodies land in <log_dir>.
#
# Ported from intel-sandbox/scalable-deploy-intel .github/actions/k8s/{engine,dynamo}.
# The manifests are rendered with envsubst into <log_dir> instead of being edited
# in place with sed -i, so the checked-out files are never modified.
set -uo pipefail

DEVICE="${1:?device (xpu|nvidia)}"
IMAGE="${2:?image}"
TEMPLATE="${3:?resource claim template}"
NODE_LABEL="${4:?node label value}"
LOG_DIR="${5:?log dir}"

NS="${NS:-dynamo-system}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SUFFIX="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
# Kueue admission plus a first pull of a multi-GB image can take a while.
RUNNING_TIMEOUT_SEC="${RUNNING_TIMEOUT_SEC:-1800}"
# Model download on a cold HF cache plus engine start-up.
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-900}"

case "$DEVICE" in
  xpu)    PREFIX="intel-gpu" ;;
  nvidia) PREFIX="nvidia-gpu" ;;
  *) echo "ERROR: unsupported device '$DEVICE' (expected xpu or nvidia)"; exit 2 ;;
esac

mkdir -p "$LOG_DIR"

kubectl get resourceclaimtemplate "$TEMPLATE" -n "$NS" >/dev/null || {
  echo "ERROR: ResourceClaimTemplate $TEMPLATE not found in $NS"; exit 1; }
kubectl get nodes -l "dynamo.intel.com/node=$NODE_LABEL" --no-headers | grep -q . || {
  echo "ERROR: no node labelled dynamo.intel.com/node=$NODE_LABEL"; exit 1; }

pod_exec() { kubectl exec -n "$NS" "$1" -- "${@:2}"; }

collect() {
  local pod="$1" dir="$2"
  mkdir -p "$dir"
  kubectl logs -n "$NS" "$pod" > "$dir/pod.log" 2>&1 || true
  kubectl describe pod -n "$NS" "$pod" > "$dir/pod-describe.txt" 2>&1 || true
  for f in nats.log etcd.log backend.log frontend.log response.json; do
    pod_exec "$pod" cat "/tmp/$f" > "$dir/$f" 2>/dev/null || rm -f "$dir/$f"
  done
}

wait_running() {
  local pod="$1" start phase
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$RUNNING_TIMEOUT_SEC" ]; do
    phase=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in
      Running) echo "Pod $pod is Running"; return 0 ;;
      Succeeded|Failed) echo "ERROR: pod $pod reached phase $phase before serving"; return 1 ;;
    esac
    echo "Waiting for $pod to be Running (phase=${phase:-none}, $(( $(date +%s) - start ))s/${RUNNING_TIMEOUT_SEC}s)"
    sleep 15
  done
  echo "ERROR: $pod not Running after ${RUNNING_TIMEOUT_SEC}s"
  return 1
}

wait_healthy() {
  local pod="$1" start phase
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$HEALTH_TIMEOUT_SEC" ]; do
    phase=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$phase" != "Running" ]; then
      echo "ERROR: pod $pod left Running (phase=$phase) while starting"
      return 1
    fi
    if pod_exec "$pod" curl -sf http://localhost:8000/health >/dev/null 2>&1; then
      echo "$pod: /health OK after $(( $(date +%s) - start ))s"
      return 0
    fi
    sleep 10
  done
  echo "ERROR: $pod: /health not OK after ${HEALTH_TIMEOUT_SEC}s"
  return 1
}

# The model the server lists. For the Dynamo pod a listed model also proves the
# worker registered with the frontend, so it is polled rather than read once.
wait_model() {
  local pod="$1" tries="$2" model=""
  for _ in $(seq 1 "$tries"); do
    model=$(pod_exec "$pod" curl -sf http://localhost:8000/v1/models 2>/dev/null \
      | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    if [ -n "$model" ]; then
      echo "$model"
      return 0
    fi
    sleep 10
  done
  return 1
}

chat() {
  local pod="$1" model="$2" prompt="$3" code
  code=$(pod_exec "$pod" curl -s -o /tmp/response.json -w '%{http_code}' \
    http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
    -d "{\"model\": \"$model\", \"messages\": [{\"role\": \"user\", \"content\": \"$prompt\"}], \"max_tokens\": 200}" 2>/dev/null)
  echo "Response ($code):"
  pod_exec "$pod" cat /tmp/response.json 2>/dev/null || true
  echo
  [ "$code" = "200" ]
}

# run_one <kind> <manifest> <model-poll-tries> <prompt>
run_one() {
  local kind="$1" manifest="$2" tries="$3" prompt="$4" pod rendered rc=0 model
  pod="sglang-smoke-${DEVICE}-${kind}-${RUN_SUFFIX}"
  pod="$(printf '%s' "$pod" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | cut -c1-63 | sed -E 's/-+$//')"
  rendered="$LOG_DIR/${kind}-rendered.yaml"

  echo "========================================="
  echo "SGLang ${kind} smoke on ${DEVICE}: pod $pod"
  echo "  image:    $IMAGE"
  echo "  template: $TEMPLATE  node: dynamo.intel.com/node=$NODE_LABEL"
  echo "========================================="

  POD_NAME="$pod" DOCKER_IMAGE="$IMAGE" RESOURCE_TEMPLATE="$TEMPLATE" NODE="$NODE_LABEL" \
    envsubst '${POD_NAME} ${DOCKER_IMAGE} ${RESOURCE_TEMPLATE} ${NODE}' < "$HERE/$manifest" > "$rendered"

  kubectl delete pod "$pod" -n "$NS" --ignore-not-found=true --wait=true
  if ! kubectl apply -n "$NS" -f "$rendered"; then
    echo "ERROR: could not create $pod"
    return 1
  fi

  if wait_running "$pod" && wait_healthy "$pod"; then
    if model=$(wait_model "$pod" "$tries"); then
      echo "Model: $model"
      chat "$pod" "$model" "$prompt" || { echo "ERROR: $kind chat completion did not return 200"; rc=1; }
    else
      echo "ERROR: no model listed on /v1/models"
      rc=1
    fi
  else
    rc=1
  fi

  collect "$pod" "$LOG_DIR/$kind"
  kubectl delete pod "$pod" -n "$NS" --ignore-not-found=true --wait=true --timeout=5m || true
  if [ "$rc" -eq 0 ]; then
    echo "PASS: SGLang ${kind} smoke on ${DEVICE}"
  else
    echo "FAIL: SGLang ${kind} smoke on ${DEVICE}"
  fi
  return "$rc"
}

engine_rc=0
dynamo_rc=0
# Engine: a healthy launch_server lists its model at once. Dynamo: registration
# through etcd/NATS can trail /health, so poll /v1/models for up to 5 minutes.
run_one engine "${PREFIX}-pod.yaml" 3 "Who is the tennis GOAT?" || engine_rc=$?
run_one dynamo "${PREFIX}-dynamo-pod.yaml" 30 "Tell me a story about a brave cat" || dynamo_rc=$?

{
  echo "### SGLang smoke (${DEVICE})"
  echo "| Pod | Result |"
  echo "|-----|--------|"
  echo "| engine (sglang.launch_server) | $([ "$engine_rc" -eq 0 ] && echo '✅ pass' || echo '❌ fail') |"
  echo "| dynamo (dynamo.sglang + frontend) | $([ "$dynamo_rc" -eq 0 ] && echo '✅ pass' || echo '❌ fail') |"
  echo ""
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

[ "$engine_rc" -eq 0 ] && [ "$dynamo_rc" -eq 0 ]
