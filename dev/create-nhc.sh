#!/bin/bash
# Creates a NodeHealthCheck CR that references an available remediator.
# Auto-detects deployed remediator templates (SNR, FAR, MDR) and uses the first found.
# Usage: create-nhc.sh [--duration <duration>]  (e.g. 300s, 5m, 1h)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Configurable unhealthy condition duration (default: 300s, matching downstream docs)
NHC_UNHEALTHY_DURATION="${NHC_UNHEALTHY_DURATION:-300s}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --duration)
            if [[ $# -lt 2 ]]; then
                echo "Error: --duration requires a value (e.g. 300s, 5m, 1h)"
                exit 1
            fi
            NHC_UNHEALTHY_DURATION="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--duration <duration>]"
            echo "  --duration   Unhealthy condition duration (default: 300s)"
            echo "  Environment: NHC_UNHEALTHY_DURATION=300s"
            exit 1
            ;;
    esac
done

# Validate duration format
if ! [[ "${NHC_UNHEALTHY_DURATION}" =~ ^([0-9]*\.?[0-9]+(ns|us|µs|ms|s|m|h))+$ ]]; then
    echo "Error: NHC_UNHEALTHY_DURATION must be a Go duration (e.g. 300s, 5m, 1h30m, 500ms), got: '${NHC_UNHEALTHY_DURATION}'"
    exit 1
fi

# Check if the NHC CRD exists
if ! ${KUBECTL} get crd nodehealthchecks.remediation.medik8s.io &>/dev/null; then
    echo "Error: NodeHealthCheck CRD not found. Deploy NHC first (make dev-deploy from the NHC directory)."
    exit 1
fi

# Auto-detect available remediator template
REMEDIATOR_API=""
REMEDIATOR_KIND=""
REMEDIATOR_NS=""
REMEDIATOR_NAME=""

# Try SNR first (most common)
if ${KUBECTL} get crd selfnoderemediationtemplates.self-node-remediation.medik8s.io &>/dev/null; then
    REMEDIATOR_NS=$(${KUBECTL} get selfnoderemediationtemplate -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | head -1)
    REMEDIATOR_NAME=$(${KUBECTL} get selfnoderemediationtemplate -A --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    if [ -n "${REMEDIATOR_NS}" ] && [ -n "${REMEDIATOR_NAME}" ]; then
        REMEDIATOR_API="self-node-remediation.medik8s.io/v1alpha1"
        REMEDIATOR_KIND="SelfNodeRemediationTemplate"
    fi
fi

# Try FAR
if [ -z "${REMEDIATOR_API}" ] && ${KUBECTL} get crd fenceagentsremediationtemplates.fence-agents-remediation.medik8s.io &>/dev/null; then
    REMEDIATOR_NS=$(${KUBECTL} get fenceagentsremediationtemplate -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | head -1)
    REMEDIATOR_NAME=$(${KUBECTL} get fenceagentsremediationtemplate -A --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    if [ -n "${REMEDIATOR_NS}" ] && [ -n "${REMEDIATOR_NAME}" ]; then
        REMEDIATOR_API="fence-agents-remediation.medik8s.io/v1alpha1"
        REMEDIATOR_KIND="FenceAgentsRemediationTemplate"
    fi
fi

# Try MDR
if [ -z "${REMEDIATOR_API}" ] && ${KUBECTL} get crd machinedeletionremediationtemplates.machine-deletion-remediation.medik8s.io &>/dev/null; then
    REMEDIATOR_NS=$(${KUBECTL} get machinedeletionremediationtemplate -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | head -1)
    REMEDIATOR_NAME=$(${KUBECTL} get machinedeletionremediationtemplate -A --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    if [ -n "${REMEDIATOR_NS}" ] && [ -n "${REMEDIATOR_NAME}" ]; then
        REMEDIATOR_API="machine-deletion-remediation.medik8s.io/v1alpha1"
        REMEDIATOR_KIND="MachineDeletionRemediationTemplate"
    fi
fi

if [ -z "${REMEDIATOR_API}" ]; then
    echo "Error: No remediator template found. Deploy a remediator first (SNR, FAR, or MDR)."
    exit 1
fi

echo "Creating NodeHealthCheck CR referencing ${REMEDIATOR_KIND} '${REMEDIATOR_NAME}' in ${REMEDIATOR_NS}..."

${KUBECTL} apply -f - <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: nhc-worker-default
spec:
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
  minHealthy: "51%"
  unhealthyConditions:
    - type: Ready
      status: "False"
      duration: ${NHC_UNHEALTHY_DURATION}
    - type: Ready
      status: Unknown
      duration: ${NHC_UNHEALTHY_DURATION}
  remediationTemplate:
    apiVersion: ${REMEDIATOR_API}
    kind: ${REMEDIATOR_KIND}
    name: ${REMEDIATOR_NAME}
    namespace: ${REMEDIATOR_NS}
EOF

echo "NodeHealthCheck 'nhc-worker-default' created."
echo ""
echo "  Remediator: ${REMEDIATOR_KIND} (${REMEDIATOR_NAME})"
echo "  Unhealthy duration: ${NHC_UNHEALTHY_DURATION}"
echo "  Override with: NHC_UNHEALTHY_DURATION=30s make dev-create-nhc"
