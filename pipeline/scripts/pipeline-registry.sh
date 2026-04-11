#!/usr/bin/env bash
# ============================================================================
# pipeline-registry.sh — Shared pipeline registry lookup
#
# Sources pipeline→instance mapping from the pipeline-registry ConfigMap
# in paperclip-v3. All scripts source this instead of hardcoded case statements.
#
# Usage (source in other scripts):
#   source "$(dirname "$0")/pipeline-registry.sh"
#
#   # Resolve a pipeline to its target instance
#   resolve_pipeline "saas"
#   echo "$PC_INSTANCE"    # pc-v4
#   echo "$PC_NAMESPACE"   # paperclip-v4
#   echo "$PC_SECRET"      # pc-v4-board-api-key
#   echo "$PC_MANIFEST"    # saas.json
#
#   # List all known pipelines
#   list_pipelines          # v1 tech wasm soa ai cf mcp ecom crypto invest saas streaming
#
#   # Resolve from CRD first, fallback to registry
#   resolve_pipeline_for_crd "pb-50301-gfh"
#
# Adding a new pipeline:
#   1. kubectl edit configmap pipeline-registry -n paperclip-v3
#   2. Or: edit manifests/pipeline-registry.yaml && kubectl apply -f ...
#   3. new-pipeline.sh does this automatically
# ============================================================================

_REGISTRY_CACHE=""
_REGISTRY_NS="paperclip-v3"
_REGISTRY_CM="pipeline-registry"

# Load registry JSON (cached per shell session)
_load_registry() {
  if [[ -z "$_REGISTRY_CACHE" ]]; then
    _REGISTRY_CACHE=$(kubectl get configmap "$_REGISTRY_CM" -n "$_REGISTRY_NS" \
      -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo '{}')
  fi
  echo "$_REGISTRY_CACHE"
}

# Resolve pipeline name → PC_INSTANCE, PC_NAMESPACE, PC_SECRET, PC_MANIFEST
# Returns 0 on success, 1 if pipeline not found
resolve_pipeline() {
  local pipeline="$1"
  local registry
  registry=$(_load_registry)

  local result
  result=$(echo "$registry" | python3 -c "
import json, sys
r = json.load(sys.stdin)
p = r.get('$pipeline')
if p:
    print(f'{p[\"instance\"]}|{p[\"namespace\"]}|{p[\"secret\"]}|{p.get(\"manifest\",\"\")}')
" 2>/dev/null)

  if [[ -n "$result" ]]; then
    IFS='|' read -r PC_INSTANCE PC_NAMESPACE PC_SECRET PC_MANIFEST <<< "$result"
    PC_DEPLOY="deploy/$PC_INSTANCE"
    export PC_INSTANCE PC_NAMESPACE PC_SECRET PC_MANIFEST PC_DEPLOY
    export NAMESPACE="$PC_NAMESPACE"
    export DEPLOY="$PC_INSTANCE"
    return 0
  fi
  return 1
}

# Resolve from CRD spec (preferred), fallback to registry
resolve_pipeline_for_crd() {
  local crd_name="$1"
  local crd_json
  crd_json=$(kubectl get pb "$crd_name" -n paperclip-v3 -o json 2>/dev/null) || return 1

  local ti tn
  ti=$(echo "$crd_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['spec'].get('targetInstance',''))" 2>/dev/null)
  tn=$(echo "$crd_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['spec'].get('targetNamespace',''))" 2>/dev/null)

  if [[ -n "$ti" ]] && [[ -n "$tn" ]]; then
    PC_INSTANCE="$ti"
    PC_NAMESPACE="$tn"
    PC_SECRET="${ti}-board-api-key"
    PC_DEPLOY="deploy/$ti"
    export PC_INSTANCE PC_NAMESPACE PC_SECRET PC_DEPLOY
    export NAMESPACE="$PC_NAMESPACE"
    export DEPLOY="$ti"
    return 0
  fi

  # Fallback: get pipeline from CRD, resolve via registry
  local pipeline
  pipeline=$(echo "$crd_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['spec'].get('pipeline',''))" 2>/dev/null)
  if [[ -n "$pipeline" ]]; then
    resolve_pipeline "$pipeline"
    return $?
  fi
  return 1
}

# List all registered pipeline names
list_pipelines() {
  local registry
  registry=$(_load_registry)
  echo "$registry" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(' '.join(sorted(r.keys())))
" 2>/dev/null
}

# Check if a pipeline exists in the registry
pipeline_exists() {
  local pipeline="$1"
  list_pipelines | grep -qw "$pipeline"
}

# Register a new pipeline in the ConfigMap
register_pipeline() {
  local pipeline="$1"
  local instance="${2:-pc-v4}"
  local namespace="${3:-paperclip-v4}"
  local manifest="${4:-${pipeline}.json}"
  local secret="${instance}-board-api-key"

  local registry
  registry=$(_load_registry)

  local updated
  updated=$(echo "$registry" | python3 -c "
import json, sys
r = json.load(sys.stdin)
r['$pipeline'] = {
    'instance': '$instance',
    'namespace': '$namespace',
    'secret': '$secret',
    'manifest': '$manifest'
}
print(json.dumps(r, indent=2))
" 2>/dev/null)

  # Patch the ConfigMap
  kubectl patch configmap "$_REGISTRY_CM" -n "$_REGISTRY_NS" --type merge \
    -p "{\"data\":{\"registry.json\":$(echo "$updated" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")}}" \
    >/dev/null 2>&1

  # Clear cache
  _REGISTRY_CACHE=""
}
