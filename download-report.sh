#!/bin/sh
# download-report.sh
#
# Downloads the IBM License Service audit snapshot and stores it.
#
# Required environment variables:
#   LICENSE_SERVICE_TOKEN  – API token for the IBM License Service
#
# Storage backend (STORAGE_BACKEND):
#   s3    (default) – upload to AWS S3
#     AWS_ACCESS_KEY_ID      – S3 access key
#     AWS_SECRET_ACCESS_KEY  – S3 secret key
#     AWS_DEFAULT_REGION     – S3 bucket region (e.g. eu-west-1)
#     S3_BUCKET              – Target S3 bucket name (e.g. illumina-ibm-license-reports)
#     S3_PREFIX              – Key prefix inside the bucket (e.g. rosa/license-reports)
#   local – save to a local directory (mount a PVC for persistence)
#     LOCAL_REPORT_DIR       – Directory to save the report (default: /reports)
#
# Optional environment variables:
#   LICENSE_SERVICE_URL    – Base URL of the License Service (default: auto-detected from
#                            Kubernetes Service env vars injected by the cluster)
#   CURL_INSECURE          – Set to "true" to skip TLS verification (dev only)
#   DRY_RUN                – Set to "true" to skip storage upload (download only — for testing)

set -eu

# LICENSE_SERVICE_URL can be set explicitly, or it is built automatically from the
# Kubernetes-injected Service env vars (available when the pod runs in the same
# namespace as the IBM License Service).
# Kubernetes injects: IBM_LICENSING_SERVICE_INSTANCE_SERVICE_HOST and
#                     IBM_LICENSING_SERVICE_INSTANCE_SERVICE_PORT_<portname>
# Run `oc -n ibm-licensing get svc` to confirm the exact Service name and port.
if [ -z "${LICENSE_SERVICE_URL:-}" ]; then
  _HOST="${IBM_LICENSING_SERVICE_INSTANCE_SERVICE_HOST:-}"
  _PORT="${IBM_LICENSING_SERVICE_INSTANCE_SERVICE_PORT_API_PORT:-${IBM_LICENSING_SERVICE_INSTANCE_SERVICE_PORT:-8080}}"
  if [ -z "${_HOST}" ]; then
    echo "[ERROR] LICENSE_SERVICE_URL is not set and IBM_LICENSING_SERVICE_INSTANCE_SERVICE_HOST is not available." >&2
    exit 1
  fi
  LICENSE_SERVICE_URL="https://${_HOST}:${_PORT}"
fi

STORAGE_BACKEND="${STORAGE_BACKEND:-s3}"
S3_PREFIX="${S3_PREFIX:-license-reports}"
LOCAL_REPORT_DIR="${LOCAL_REPORT_DIR:-/reports}"
CURL_OPTS=""
if [ "${CURL_INSECURE:-false}" = "true" ]; then
  CURL_OPTS="-k"
fi

# Timestamp used for the filename: YYYY-MM-DD
TIMESTAMP="$(date -u '+%Y-%m-%d')"
REPORT_FILE="/tmp/license-report-${TIMESTAMP}.zip"

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Downloading IBM License Service audit snapshot..."

HTTP_STATUS=$(curl ${CURL_OPTS} \
  --silent \
  --show-error \
  --output "${REPORT_FILE}" \
  --write-out "%{http_code}" \
  --max-time 120 \
  "${LICENSE_SERVICE_URL}/snapshot?token=${LICENSE_SERVICE_TOKEN}")

if [ "${HTTP_STATUS}" != "200" ]; then
  echo "[ERROR] License Service returned HTTP ${HTTP_STATUS}. Check the token and URL." >&2
  rm -f "${REPORT_FILE}"
  exit 1
fi

FILE_SIZE=$(wc -c < "${REPORT_FILE}")
echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Downloaded ${FILE_SIZE} bytes → ${REPORT_FILE}"

# Store report (skipped when DRY_RUN=true)
if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] DRY_RUN=true — skipping storage. Report saved at ${REPORT_FILE}"
  exit 0
fi

case "${STORAGE_BACKEND}" in

  s3)
    S3_KEY="${S3_PREFIX}/${TIMESTAMP}/license-report-${TIMESTAMP}.zip"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Uploading to s3://${S3_BUCKET}/${S3_KEY} ..."
    aws s3 cp "${REPORT_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" \
      --no-progress \
      --sse aws:kms
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Upload complete."
    rm -f "${REPORT_FILE}"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Done. Report archived at s3://${S3_BUCKET}/${S3_KEY}"
    ;;

  local)
    DEST_DIR="${LOCAL_REPORT_DIR}/${TIMESTAMP}"
    mkdir -p "${DEST_DIR}"
    DEST_FILE="${DEST_DIR}/license-report-${TIMESTAMP}.zip"
    cp "${REPORT_FILE}" "${DEST_FILE}"
    rm -f "${REPORT_FILE}"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Done. Report saved at ${DEST_FILE}"
    ;;

  *)
    echo "[ERROR] Unknown STORAGE_BACKEND '${STORAGE_BACKEND}'. Supported values: s3, local" >&2
    rm -f "${REPORT_FILE}"
    exit 1
    ;;

esac
