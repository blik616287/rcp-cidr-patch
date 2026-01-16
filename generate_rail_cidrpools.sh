#!/usr/bin/env bash
set -euo pipefail

# generate_rail_cidrpools.sh (macOS/bash 3.2 compatible)
# Usage:
#   ./generate_rail_cidrpools.sh -i ./data -o ./out [-n nvidia-network-operator]
#
# Requires:
#   - yq v4+   (brew install yq)
#   - jq       (brew install jq)

INPUT_DIR=""
OUTPUT_DIR=""
NAMESPACE="nvidia-network-operator"
SUBNET_PREFIX=""  # Will be auto-detected if not specified

while getopts ":i:o:n:p:" opt; do
  case "$opt" in
    i) INPUT_DIR="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    n) NAMESPACE="$OPTARG" ;;
    p) SUBNET_PREFIX="$OPTARG" ;;
    *) echo "Usage: $0 -i <input_dir> -o <output_dir> [-n <namespace>] [-p <subnet_prefix>]" >&2; exit 1 ;;
  esac
done

if [[ -z "${INPUT_DIR}" || -z "${OUTPUT_DIR}" ]]; then
  echo "Usage: $0 -i <input_dir> -o <output_dir> [-n <namespace>] [-p <subnet_prefix>]" >&2
  echo "  -p: Subnet prefix (29, 30, or 31). Auto-detected from netplan files if not specified."
  exit 1
fi

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq v4+ is required."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required."; exit 1; }

# Ensure we have Mike Farah yq
if ! yq --version 2>/dev/null | grep -qi 'mikefarah/yq'; then
  echo "ERROR: Need Mike Farah yq v4+. Current is: $(yq --version || true)"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# Rail → interface map (1-based indices; ignore index 0)
RAIL_IFACE=()
RAIL_IFACE[1]="eth1"
RAIL_IFACE[2]="eth2"
RAIL_IFACE[3]="eth3"
RAIL_IFACE[4]="eth4"
#RAIL_IFACE[5]="ens37f0np0"
#RAIL_IFACE[6]="ens34f0np0"
#RAIL_IFACE[7]="ens36f0np0"
#RAIL_IFACE[8]="ens35f0np0"
NUM_RAILS=$(echo "${RAIL_IFACE[@]}" | wc -w)

# Arrays to hold per-rail state
RAIL_ROUTES_JSON=()   # JSON array string, e.g. '[{"dst":"x/y"}, ...]'
RAIL_CIDR=()          # chosen CIDR per rail (most specific 'to' or fallback)
RAIL_ALLOC_JSON=()    # JSON array of staticAllocations per rail

most_specific() {
  # Return the CIDR with the larger prefix (more specific)
  local A="$1" B="$2"
  local PA="${A##*/}" PB="${B##*/}"
  if [[ "$PA" -ge "$PB" ]]; then echo "$A"; else echo "$B"; fi
}

SEED="${INPUT_DIR}/hgx-su00-h00.yaml"
if [[ ! -f "$SEED" ]]; then
  echo "ERROR: Seed file '$SEED' not found." >&2
  exit 1
fi

# Auto-detect subnet prefix from seed file if not specified
if [[ -z "$SUBNET_PREFIX" ]]; then
  # Extract prefix from first interface address (e.g., "172.16.0.0/31" -> "31")
  FIRST_ADDR="$(yq -r ".network.ethernets.eth1.addresses[0]" "$SEED" 2>/dev/null || true)"
  if [[ -n "$FIRST_ADDR" && "$FIRST_ADDR" != "null" && "$FIRST_ADDR" == *"/"* ]]; then
    SUBNET_PREFIX="${FIRST_ADDR##*/}"
    echo "Auto-detected subnet prefix: /${SUBNET_PREFIX}"
  else
    SUBNET_PREFIX="31"
    echo "WARN: Could not auto-detect subnet prefix, defaulting to /31"
  fi
fi

# Validate subnet prefix
if [[ ! "$SUBNET_PREFIX" =~ ^(29|30|31)$ ]]; then
  echo "ERROR: Invalid subnet prefix '${SUBNET_PREFIX}'. Must be 29, 30, or 31." >&2
  exit 1
fi

# Seed per-rail routes & cidr from hgx-su00-h00.yaml
r=1
while [[ $r -le $NUM_RAILS ]]; do
  IFACE="${RAIL_IFACE[$r]}"
  IFS=$'\n' read -r -d '' -a ROUTES < <(yq -r ".network.ethernets.${IFACE}.routes[].to" "$SEED" 2>/dev/null || true; printf '\0')
  local_routes_json="[]"
  most_spec=""
  for to in "${ROUTES[@]:-}"; do
    [[ -z "${to:-}" ]] && continue
    local_routes_json=$(jq -c --arg dst "$to" '. + [{"dst":$dst}]' <<<"$local_routes_json")
    if [[ -z "$most_spec" ]]; then
      most_spec="$to"
    else
      most_spec="$(most_specific "$most_spec" "$to")"
    fi
  done

  if [[ -z "$most_spec" ]]; then
    ADDR="$(yq -r ".network.ethernets.${IFACE}.addresses[0]" "$SEED" 2>/dev/null || true)"
    if [[ -n "$ADDR" && "$ADDR" != "null" ]]; then
      most_spec="$ADDR"
    else
      most_spec="10.0.0.0/24"
    fi
  fi

  RAIL_ROUTES_JSON[$r]="$local_routes_json"
  RAIL_CIDR[$r]="$most_spec"
  RAIL_ALLOC_JSON[$r]="[]"
  r=$((r+1))
done

shopt -s nullglob
for FILE in "${INPUT_DIR}"/hgx-su*.yaml; do
  BASENAME="$(basename "$FILE")"
  NODENAME="${BASENAME%.yaml}"   # e.g., hgx-su03-h16.yaml

  r=1
  while [[ $r -le $NUM_RAILS ]]; do
    IFACE="${RAIL_IFACE[$r]}"
    PREFIX="$(yq -r ".network.ethernets.${IFACE}.addresses[0]" "$FILE" 2>/dev/null || true)"
    [[ "$PREFIX" == "null" ]] && PREFIX=""
    GATEWAY="$(yq -r ".network.ethernets.${IFACE}.routes[0].via" "$FILE" 2>/dev/null || true)"
    [[ "$GATEWAY" == "null" ]] && GATEWAY=""

    if [[ -n "$PREFIX" && -n "$GATEWAY" ]]; then
      current="${RAIL_ALLOC_JSON[$r]}"
      NEW=$(jq -c --arg gw "$GATEWAY" --arg nn "$NODENAME" --arg pf "$PREFIX" \
        '. + [{"gateway":$gw, "nodeName":$nn, "prefix":$pf}]' <<<"$current")
      RAIL_ALLOC_JSON[$r]="$NEW"
    else
      echo "WARN: Skipping ${NODENAME} rail ${r} (${IFACE}) due to missing prefix/gateway." >&2
    fi
    r=$((r+1))
  done
done

# Emit CIDRPool YAMLs (build with jq, pretty YAML with yq)
r=1
while [[ $r -le $NUM_RAILS ]]; do
  NAME="rail-${r}"
  OUT="${OUTPUT_DIR}/${NAME}-cidrpool.yaml"
  ROUTES_JSON="${RAIL_ROUTES_JSON[$r]}"
  ALLOCS_JSON="${RAIL_ALLOC_JSON[$r]}"
  CIDR_VAL="${RAIL_CIDR[$r]}"

  jq -n \
    --arg api "nv-ipam.nvidia.com/v1alpha1" \
    --arg kind "CIDRPool" \
    --arg name "$NAME" \
    --arg ns "$NAMESPACE" \
    --arg cidr "$CIDR_VAL" \
    --argjson prefix "$SUBNET_PREFIX" \
    --argjson routes "$ROUTES_JSON" \
    --argjson allocs "$ALLOCS_JSON" \
    '{
      apiVersion: $api,
      kind: $kind,
      metadata: { name: $name, namespace: $ns },
      spec: {
        cidr: $cidr,
        gatewayIndex: 0,
        perNodeNetworkPrefix: $prefix,
        routes: $routes,
        staticAllocations: $allocs
      }
    }' \
  | yq -P > "$OUT"

  echo "Wrote ${OUT}"
  r=$((r+1))
done

echo "CIDRPool generation complete."
echo
echo "Output YAML can be presented with the following command:"
echo '  for i in $(ls *-cidrpool.yaml); do echo "---" && cat $i; done'
