# IBM License Service Report Downloader

Automates the retrieval of IBM License Service audit snapshots from an OpenShift cluster and archives them for compliance purposes. Supports AWS S3 and local storage (PVC) backends.

---

## Overview

The **IBM License Service** (operator `ibm-licensing-operator-app`, namespace `ibm-licensing`) continuously polls running containers, identifies IBM software via predefined labels, and tracks usage within its cluster.

This repo provides a **Kubernetes CronJob** that:
1. Calls the License Service REST API to download the audit snapshot (`.zip`).
2. Stores the snapshot — either in AWS S3 or on a mounted PVC (on-prem / other clouds).

---

## Repository Structure

```
├── Dockerfile                        # Container image (amazonlinux + curl + AWS CLI v2)
├── download-report.sh                # Entrypoint script
└── deploy/
    ├── rbac.yaml                     # ServiceAccount, Role, RoleBinding
    ├── secrets.yaml                  # Secret templates (fill before applying — never commit secrets)
    └── cronjob.yaml                  # CronJob (monthly schedule)
```

---

## Prerequisites

| Requirement | Details |
|---|---|
| IBM License Service installed | Operator `ibm-licensing-operator-app` in namespace `ibm-licensing` |
| Container registry | Build the image and push to your internal registry |
| OpenShift cluster | Uses OpenShift restricted SCC (non-root, read-only root FS) |
| **S3 backend only** S3 bucket | Create `illumina-ibm-license-reports` (or update `S3_BUCKET` in `secrets.yaml`) |
| **S3 backend only** S3 IAM permissions | `s3:PutObject` on the target bucket + prefix |
| **Local backend only** PVC | A PVC named `ibm-license-reports-pvc` in `ibm-licensing` |

---

## Step 1 — Build and Push the Container Image

```bash
docker build -t <your-registry>/ibm-license-reporter:latest .
docker push <your-registry>/ibm-license-reporter:latest
```

Update `deploy/cronjob.yaml` → `spec.jobTemplate.spec.template.spec.containers[0].image` with your registry URL.

A GitHub Actions workflow (`.github/workflows/docker-build.yml`) is included to build and push automatically on every push to `main` or on a tag. By default it pushes to **GitHub Container Registry** (`ghcr.io`). See the workflow file to switch to a private registry.

---

## Step 2 — Choose a Storage Backend

Set `STORAGE_BACKEND` in `deploy/secrets.yaml` to control where the report is saved after download.

| Value | Description | When to use |
|---|---|---|
| `s3` _(default)_ | Upload to AWS S3 | AWS ROSA or any S3-compatible store |
| `local` | Save to a directory on a mounted PVC | On-prem OpenShift, no cloud storage |

---

### S3 backend

## Step 2a — Configure S3 Credentials

### Option A — Static credentials (simple, less secure)

Fill in the AWS credentials in `deploy/secrets.yaml`.

### Option B — IRSA / Pod Identity (recommended for ROSA)

1. Create an IAM role with `s3:PutObject` permission on your bucket.
2. Annotate the ServiceAccount in `deploy/rbac.yaml`:
   ```yaml
   annotations:
     eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/LicenseReporterS3Role
   ```
3. Remove `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from `deploy/secrets.yaml`.

---

### Local backend

## Step 2b — Configure Local Storage (on-prem / no cloud)

1. Create a PVC in the `ibm-licensing` namespace:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: ibm-license-reports-pvc
     namespace: ibm-licensing
   spec:
     accessModes: [ReadWriteOnce]
     resources:
       requests:
         storage: 1Gi
   ```

2. In `deploy/secrets.yaml`, uncomment and apply the `local` Secret block instead of the S3 one.

3. In `deploy/cronjob.yaml`, uncomment the `reports` volume and volumeMount.

---

## Step 3 — Apply to Your Cluster

```bash
# 1. RBAC
oc apply -f deploy/rbac.yaml

# 2. Secrets (fill actual values first — do NOT commit to git)
oc apply -f deploy/secrets.yaml

# 3. CronJob
oc apply -f deploy/cronjob.yaml
```

Verify:

```bash
oc -n ibm-licensing get cronjob ibm-license-reporter
```

---

## Step 4 — Trigger a Manual Test Run

```bash
oc -n ibm-licensing create job --from=cronjob/ibm-license-reporter license-reporter-test
oc -n ibm-licensing logs -l app.kubernetes.io/name=ibm-license-reporter --follow
```

---

## Local Testing (without Kubernetes)

Use `DRY_RUN=true` to test the download without S3:

```bash
export LICENSE_SERVICE_TOKEN="<your-token>"
export LICENSE_SERVICE_URL="https://ibm-licensing-service-instance-ibm-licensing.apps.<cluster-domain>"
export CURL_INSECURE="true"
export DRY_RUN="true"

sh download-report.sh
```

The report zip is saved to `/tmp/license-report-<date>.zip`.

---

## How the License Service URL is Resolved

When the CronJob pod runs in the `ibm-licensing` namespace, Kubernetes automatically injects Service environment variables for every Service in that namespace. The script reads:

```
IBM_LICENSING_SERVICE_INSTANCE_SERVICE_HOST   → cluster IP of the Service
IBM_LICENSING_SERVICE_INSTANCE_SERVICE_PORT_API_PORT → port (8080)
```

No URL configuration is needed in-cluster. Set `LICENSE_SERVICE_URL` explicitly only when running outside the cluster (local testing) or if the auto-detection fails.

---

## Schedule

| Schedule | Cron expression | Notes |
|---|---|---|
| Monthly (default) | `0 2 1 * *` | 1st of every month at 02:00 UTC |
| Quarterly | `0 2 1 */3 *` | Minimum required for audit |
| Weekly | `0 2 * * 1` | Recommended for high-compliance environments |

---

## S3 Bucket Layout

```
s3://illumina-ibm-license-reports/
└── rosa/
    └── license-reports/
        ├── 2026-01-01/
        │   └── license-report-2026-01-01.zip
        └── ...
```

**Recommended S3 lifecycle policy:**
- Transition to Glacier after 90 days.
- Minimum retention: **13 months** for compliance; **5 years** for audit archives.
- Enable S3 Object Lock (WORM) for immutable audit evidence.

---

## Environment Variables Reference

| Variable | Source | Description |
|---|---|---|
| `LICENSE_SERVICE_TOKEN` | Secret `ibm-licensing-token` (operator-managed) | API token for the License Service |
| `LICENSE_SERVICE_URL` | Optional env override | Base URL — auto-detected in-cluster if not set |
| `STORAGE_BACKEND` | Secret `ibm-license-reporter-s3` | `s3` (default) or `local` |
| `AWS_ACCESS_KEY_ID` | Secret `ibm-license-reporter-s3` | S3 only — AWS access key (omit when using IRSA) |
| `AWS_SECRET_ACCESS_KEY` | Secret `ibm-license-reporter-s3` | S3 only — AWS secret key (omit when using IRSA) |
| `AWS_DEFAULT_REGION` | Secret `ibm-license-reporter-s3` | S3 only — bucket region |
| `S3_BUCKET` | Secret `ibm-license-reporter-s3` | S3 only — target bucket name |
| `S3_PREFIX` | Secret `ibm-license-reporter-s3` | S3 only — key prefix inside the bucket |
| `LOCAL_REPORT_DIR` | Secret `ibm-license-reporter-s3` | Local only — target directory (default: `/reports`) |
| `CURL_INSECURE` | Optional env | Set `true` to skip TLS verification (dev only) |
| `DRY_RUN` | Optional env | Set `true` to skip storage step (testing only) |
