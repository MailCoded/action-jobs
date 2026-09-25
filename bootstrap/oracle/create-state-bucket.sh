#!/usr/bin/env bash
set -uo pipefail

readonly TAGS='{"ManagedBy":"bootstrap","Hub":"freebie-hub","Purpose":"terraform-state"}'

TENANCY_OCID="${TENANCY_OCID:-}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:-$TENANCY_OCID}"
BUCKET="${BUCKET:-freebie-hub-tfstate}"
OCI_REGION="${OCI_REGION:-ap-sydney-1}"
export SUPPRESS_LABEL_WARNING="${SUPPRESS_LABEL_WARNING:-True}"

WORK_DIR=""
BUCKET_COMPARTMENT=""

usage() {
  cat <<'EOF'
Create (or check) the private, versioned Object Storage bucket that holds the Terraform state.
Idempotent: safe to run again. Run it with an admin CLI profile; the bucket is never managed by Terraform.

Usage:
  TENANCY_OCID=ocid1.tenancy.oc1..xxxx bootstrap/oracle/create-state-bucket.sh

Environment:
  TENANCY_OCID      required
  COMPARTMENT_OCID  compartment for a new bucket (default: the tenancy, i.e. root)
  BUCKET            bucket name (default: freebie-hub-tfstate)
  OCI_REGION        region of the bucket; must match the OCI_REGION repository variable (default: ap-sydney-1)
  OCI_CLI_PROFILE   OCI CLI profile to use (default: the CLI's DEFAULT profile)

Exit status: 0 bucket ready, 1 error.
EOF
}

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}

oci_cli() {
  if [[ -n "${OCI_CLI_PROFILE:-}" ]]; then
    oci --profile "$OCI_CLI_PROFILE" --region "$OCI_REGION" "$@" </dev/null
  else
    oci --region "$OCI_REGION" "$@" </dev/null
  fi
}

show_err() {
  [[ -s "$1" ]] && sed 's/^/  /' "$1" >&2
  return 0
}

err_has() {
  grep -qE -- "$2" "$1" 2>/dev/null
}

get_bucket() {
  oci_cli os bucket get --namespace-name "$1" --bucket-name "$BUCKET" 2>"$WORK_DIR/get.err"
}

ensure_settings() {
  local ns="$1" json="$2" versioning access args=() changes=() joined
  versioning="$(jq -r '.data.versioning // "unknown"' <<<"$json")"
  access="$(jq -r '.data."public-access-type" // "unknown"' <<<"$json")"
  BUCKET_COMPARTMENT="$(jq -r '.data."compartment-id" // empty' <<<"$json")"
  say "Bucket '${BUCKET}' already exists (versioning: ${versioning}, public access: ${access})."

  if [[ "$versioning" != "Enabled" ]]; then
    args+=(--versioning Enabled)
    changes+=("versioning ${versioning} -> Enabled")
  fi
  if [[ "$access" != "NoPublicAccess" ]]; then
    args+=(--public-access-type NoPublicAccess)
    changes+=("public access ${access} -> NoPublicAccess")
  fi
  if ((${#changes[@]} == 0)); then
    say "Settings are already correct; nothing changed."
    return 0
  fi

  joined="$(printf '%s, ' "${changes[@]}")"
  if ! oci_cli os bucket update --namespace-name "$ns" --bucket-name "$BUCKET" "${args[@]}" \
    >/dev/null 2>"$WORK_DIR/update.err"; then
    show_err "$WORK_DIR/update.err"
    die "Could not update bucket '${BUCKET}' (${joined%, }). The profile needs 'manage buckets' on the bucket's compartment."
  fi
  printf 'Changed: %s\n' "${changes[@]}"
}

create_bucket() {
  local ns="$1" json
  say "Bucket '${BUCKET}' not found (or not visible to this profile); creating it in ${COMPARTMENT_OCID}..."
  if oci_cli os bucket create --namespace-name "$ns" --name "$BUCKET" --compartment-id "$COMPARTMENT_OCID" \
    --public-access-type NoPublicAccess --versioning Enabled --storage-tier Standard \
    --freeform-tags "$TAGS" >/dev/null 2>"$WORK_DIR/create.err"; then
    BUCKET_COMPARTMENT="$COMPARTMENT_OCID"
    say "Created private, versioned bucket '${BUCKET}'."
    return 0
  fi

  if err_has "$WORK_DIR/create.err" '"status": ?409'; then
    say "Create returned 409; checking whether the bucket exists after all..."
    if json="$(get_bucket "$ns")"; then
      ensure_settings "$ns" "$json"
      return 0
    fi
    show_err "$WORK_DIR/create.err"
    die "Create returned 409 but the bucket is still not visible. A 409 also means 'not authorised to create': use an admin profile (OCI_CLI_PROFILE), or choose another BUCKET name."
  fi

  show_err "$WORK_DIR/create.err"
  if err_has "$WORK_DIR/create.err" '"status": ?40[134]|NotAuthorizedOrNotFound|NotAuthenticated'; then
    die "Not allowed to create bucket '${BUCKET}' in ${COMPARTMENT_OCID}. Run with an admin profile (OCI_CLI_PROFILE) that may 'manage buckets' there."
  fi
  die "Could not create bucket '${BUCKET}' in ${COMPARTMENT_OCID}."
}

print_next_steps() {
  local ns="$1" location
  if [[ -z "$BUCKET_COMPARTMENT" || "$BUCKET_COMPARTMENT" == "$TENANCY_OCID" ]]; then
    location="tenancy"
  else
    location="compartment id ${BUCKET_COMPARTMENT}"
  fi
  cat <<EOF

State bucket ready: ${BUCKET} (region ${OCI_REGION}, namespace ${ns})

Add to GitHub (Settings -> Secrets and variables -> Actions):
  Variable  OCI_STATE_BUCKET     = ${BUCKET}
  Secret    OCI_STATE_NAMESPACE  = ${ns}
EOF
  if [[ "$OCI_REGION" != "ap-sydney-1" ]]; then
    printf '  Variable  OCI_REGION           = %s\n' "$OCI_REGION"
  fi
  cat <<EOF

In bootstrap/oracle/iam-policy.txt use:
  <state-bucket>     = ${BUCKET}
  <bucket-location>  = ${location}
EOF
}

main() {
  local problems=() ns json cmd
  if (($# > 0)); then
    usage
    [[ "$1" == "-h" || "$1" == "--help" ]] && exit 0
    exit 1
  fi

  [[ "$TENANCY_OCID" =~ ^ocid1\.tenancy\. ]] || problems+=("TENANCY_OCID must be set to the tenancy OCID (ocid1.tenancy...)")
  [[ -z "$COMPARTMENT_OCID" || "$COMPARTMENT_OCID" =~ ^ocid1\.(tenancy|compartment)\. ]] || problems+=("COMPARTMENT_OCID must be a compartment or tenancy OCID")
  [[ "$BUCKET" =~ ^[A-Za-z0-9._-]+$ ]] || problems+=("BUCKET may only contain letters, digits, '.', '_' and '-' (got '${BUCKET}')")
  [[ "$OCI_REGION" =~ ^[a-z]+-[a-z]+-[0-9]+$ ]] || problems+=("OCI_REGION must look like ap-sydney-1 (got '${OCI_REGION}')")
  if ((${#problems[@]} > 0)); then
    printf 'ERROR: %s\n' "${problems[@]}" >&2
    printf '\n' >&2
    usage >&2
    exit 1
  fi
  for cmd in oci jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
  done

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/create-state-bucket.XXXXXX")" || die "Could not create a temporary directory."
  trap cleanup EXIT

  say "OCI CLI profile: ${OCI_CLI_PROFILE:-DEFAULT}, region: ${OCI_REGION}"
  if ! ns="$(oci_cli os ns get --query data --raw-output 2>"$WORK_DIR/ns.err")" || [[ -z "$ns" ]]; then
    show_err "$WORK_DIR/ns.err"
    die "Could not read the Object Storage namespace. Check the CLI profile (OCI_CLI_PROFILE), its API key and region."
  fi
  say "Object Storage namespace: ${ns}"

  if json="$(get_bucket "$ns")"; then
    ensure_settings "$ns" "$json"
  elif err_has "$WORK_DIR/get.err" '"code": ?"BucketNotFound"'; then
    create_bucket "$ns"
  else
    show_err "$WORK_DIR/get.err"
    die "Could not look up bucket '${BUCKET}'."
  fi

  print_next_steps "$ns"
}

main "$@"
