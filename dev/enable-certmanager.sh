#!/bin/bash
# Creates cert-manager Certificate for an operator's webhook and patches
# the deployment to mount the TLS secret.
# Usage: enable-certmanager.sh <namespace> <deployment-name> <service-name>

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <namespace> <deployment-name> <service-name>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

NAMESPACE="$1"
DEPLOY_NAME="$2"
SERVICE_NAME="$3"

# Check if certificate already exists and is ready AND deployment has the volume mount
if ${KUBECTL} get certificate serving-cert -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    if ${KUBECTL} get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null | grep -q cert; then
        echo "  cert-manager already configured in ${NAMESPACE}."
        exit 0
    fi
    echo "  Certificate ready but deployment needs patching..."
fi

echo "  Creating cert-manager Issuer and Certificate in ${NAMESPACE}..."

# Retry the apply — cert-manager webhook may not be ready immediately after deployment
for i in $(seq 1 30); do
    if ${KUBECTL} apply -f - <<INNEREOF 2>/dev/null
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: ${NAMESPACE}
spec:
  selfSigned: {}
INNEREOF
    then
        break
    fi
    if [ "$i" -eq 1 ]; then
        echo "  Waiting for cert-manager webhook to accept requests..."
    fi
    if [ "$i" -eq 30 ]; then
        echo "  Error: cert-manager webhook not ready after 30s." >&2
        exit 1
    fi
    sleep 1
done

${KUBECTL} apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: serving-cert
  namespace: ${NAMESPACE}
spec:
  dnsNames:
  - ${SERVICE_NAME}.${NAMESPACE}.svc
  - ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local
  issuerRef:
    kind: Issuer
    name: selfsigned-issuer
  secretName: webhook-server-cert
EOF

echo "  Waiting for certificate to be ready..."
${KUBECTL} wait --for=condition=Ready certificate/serving-cert -n "${NAMESPACE}" --timeout=60s

# Annotate webhook configurations for CA injection
for wh_type in mutatingwebhookconfigurations validatingwebhookconfigurations; do
    for wh in $(${KUBECTL} get "${wh_type}" -o name 2>/dev/null); do
        # Only annotate webhooks whose clientConfig targets our namespace
        if ${KUBECTL} get "${wh}" -o jsonpath='{range .webhooks[*]}{.clientConfig.service.namespace}{"\n"}{end}' 2>/dev/null | grep -Fxq -- "${NAMESPACE}"; then
            ${KUBECTL} annotate "${wh}" cert-manager.io/inject-ca-from="${NAMESPACE}/serving-cert" --overwrite 2>/dev/null || true
        fi
    done
done

# Patch deployment to mount the TLS secret at the path controller-runtime expects
if ${KUBECTL} get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null | grep -q cert; then
    echo "  Deployment already has TLS volume mount — skipping patch."
else
    CONTAINER_NAME=$(${KUBECTL} get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].name}')
    echo "  Patching deployment to mount webhook TLS secret (container: ${CONTAINER_NAME})..."
    ${KUBECTL} patch deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" --type=strategic -p='{
      "spec": {
        "template": {
          "spec": {
            "volumes": [{
              "name": "cert",
              "secret": {
                "secretName": "webhook-server-cert",
                "defaultMode": 420
              }
            }],
            "containers": [{
              "name": "'"${CONTAINER_NAME}"'",
              "volumeMounts": [{
                "name": "cert",
                "mountPath": "/tmp/k8s-webhook-server/serving-certs",
                "readOnly": true
              }]
            }]
          }
        }
      }
    }'
    echo "  Waiting for rollout..."
    ${KUBECTL} rollout status deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" --timeout=120s
fi
