#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Reproducible, checksum-verified installer for Kubernetes command-line tools.
# Intended for Linux container-image builds and CI worker images.
#
# Supported tools: kubectl, kustomize, kind, helm
# Supported common architectures: amd64, arm64
# Additional architectures are accepted where the upstream project publishes them.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022
export LC_ALL=C

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_USER_AGENT="${SCRIPT_NAME}/1.0"

: "${INSTALL_DIR:=/usr/local/bin}"
: "${TOOLS:=kubectl kustomize kind helm}"
: "${TARGETOS:=linux}"
: "${TARGETARCH:=}"
: "${DOWNLOAD_CACHE_DIR:=}"
: "${OFFLINE:=0}"
: "${CHECKSUM_POLICY:=remote}"
: "${ALLOW_INSECURE_INSTALL_DIR:=0}"
: "${CURL_CONNECT_TIMEOUT:=15}"
: "${CURL_MAX_TIME:=300}"
: "${CURL_RETRIES:=5}"
: "${HTTP_USER_AGENT:=${DEFAULT_USER_AGENT}}"

# Deliberately pinned defaults. Override in Dockerfiles with build arguments.
: "${KUBECTL_VERSION:=v1.36.1}"
: "${KUSTOMIZE_VERSION:=v5.8.1}"
: "${KIND_VERSION:=v0.32.0}"
: "${HELM_VERSION:=v4.1.4}"

# Optional immutable SHA-256 pins. When CHECKSUM_POLICY=pinned, each selected
# tool must have its corresponding variable populated.
: "${KUBECTL_SHA256:=}"
: "${KUSTOMIZE_SHA256:=}"
: "${KIND_SHA256:=}"
: "${HELM_SHA256:=}"

# Architecture-specific pins take precedence over the generic values above.
# Additional suffixes such as _PPC64LE, _S390X, _386, and _ARM are resolved
# dynamically when those architectures are selected.
: "${KUBECTL_SHA256_AMD64:=}"
: "${KUBECTL_SHA256_ARM64:=}"
: "${KUSTOMIZE_SHA256_AMD64:=}"
: "${KUSTOMIZE_SHA256_ARM64:=}"
: "${KIND_SHA256_AMD64:=}"
: "${KIND_SHA256_ARM64:=}"
: "${HELM_SHA256_AMD64:=}"
: "${HELM_SHA256_ARM64:=}"

# Optional Sigstore verification for kubectl. Requires a trusted, preinstalled
# cosign binary. Checksum verification is still performed.
: "${KUBECTL_VERIFY_SIGNATURE:=0}"
: "${VERIFY_EXECUTABLE:=auto}"

TMP_ROOT=""
ARCH=""

log() {
  printf '%s\n' "${SCRIPT_NAME}: $*" >&2
}

warn() {
  printf '%s\n' "${SCRIPT_NAME}: warning: $*" >&2
}

die() {
  printf '%s\n' "${SCRIPT_NAME}: error: $*" >&2
  exit 1
}

cleanup() {
  local rc=$?
  if [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]]; then
    rm -rf -- "${TMP_ROOT}"
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat <<'USAGE'
Usage:
  install-k8s-tools.sh [tool ...]

Tools:
  kubectl kustomize kind helm

Configuration is environment-driven for Docker/BuildKit compatibility:
  INSTALL_DIR=/usr/local/bin
  TARGETOS=linux
  TARGETARCH=amd64|arm64|ppc64le|s390x
  TOOLS="kubectl kustomize kind helm"
  CHECKSUM_POLICY=remote|pinned
  DOWNLOAD_CACHE_DIR=/path/to/cache
  OFFLINE=0|1

Version pins:
  KUBECTL_VERSION=v1.36.1
  KUSTOMIZE_VERSION=v5.8.1
  KIND_VERSION=v0.32.0
  HELM_VERSION=v4.1.4

Optional immutable checksum pins:
  KUBECTL_SHA256=<64 hex characters>
  KUSTOMIZE_SHA256=<64 hex characters>
  KIND_SHA256=<64 hex characters>
  HELM_SHA256=<64 hex characters>

Architecture-specific pins take precedence, for example:
  KUBECTL_SHA256_AMD64=<64 hex characters>
  KUBECTL_SHA256_ARM64=<64 hex characters>

High-assurance mode:
  CHECKSUM_POLICY=pinned KUBECTL_SHA256=... ./install-k8s-tools.sh kubectl

Optional kubectl Sigstore verification:
  KUBECTL_VERIFY_SIGNATURE=1 ./install-k8s-tools.sh kubectl

Cross-platform builds:
  VERIFY_EXECUTABLE=auto|1|0
USAGE
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_boolean() {
  local name=$1 value=$2
  case "${value}" in
    0|1) ;;
    *) die "${name} must be 0 or 1, got: ${value}" ;;
  esac
}

validate_uint() {
  local name=$1 value=$2 minimum=${3:-0}
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be an unsigned integer, got: ${value}"
  (( value >= minimum )) || die "${name} must be at least ${minimum}, got: ${value}"
}

validate_no_control_chars() {
  local name=$1 value=$2
  [[ ! "${value}" =~ [[:cntrl:]] ]] || die "${name} contains control characters"
}

assert_no_symlink_components() {
  local path=$1 component current="/"
  local -a components=()
  IFS='/' read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    if [[ -L "${current}" ]]; then
      if [[ "${ALLOW_INSECURE_INSTALL_DIR}" == 1 ]]; then
        warn "path contains symbolic-link component: ${current}"
      else
        die "path contains symbolic-link component: ${current}"
      fi
    fi
  done
}

validate_version() {
  local tool=$1 version=$2
  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] ||
    die "invalid ${tool} version: ${version}"
}

validate_sha256() {
  local label=$1 value=${2,,}
  [[ ${#value} -eq 64 && ! "${value}" =~ [^0-9a-f] ]] ||
    die "invalid SHA-256 for ${label}"
}

normalize_platform() {
  local raw_arch

  [[ "${TARGETOS,,}" == "linux" ]] ||
    die "only Linux targets are supported; TARGETOS=${TARGETOS}"

  raw_arch=${TARGETARCH:-$(uname -m)}
  case "${raw_arch,,}" in
    amd64|x86_64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    ppc64le) ARCH=ppc64le ;;
    s390x) ARCH=s390x ;;
    386|i386|i686) ARCH=386 ;;
    arm|armv7|armv7l) ARCH=arm ;;
    *) die "unsupported architecture: ${raw_arch}" ;;
  esac
}

stat_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

stat_uid() {
  if stat -c '%u' "$1" >/dev/null 2>&1; then
    stat -c '%u' "$1"
  else
    stat -f '%u' "$1"
  fi
}

validate_directory_security() {
  local directory=$1 label=$2 mode owner

  validate_no_control_chars "${label}" "${directory}"
  [[ "${directory}" == /* ]] || die "${label} must be an absolute path: ${directory}"
  [[ ! -L "${directory}" ]] || die "${label} must not be a symbolic link: ${directory}"
  assert_no_symlink_components "${directory}"
  mkdir -p -- "${directory}"
  assert_no_symlink_components "${directory}"
  [[ -d "${directory}" ]] || die "${label} is not a directory: ${directory}"

  mode=$(stat_mode "${directory}")
  if (( (8#${mode} & 0002) != 0 )); then
    if [[ "${ALLOW_INSECURE_INSTALL_DIR}" == 1 ]]; then
      warn "${label} is world-writable: ${directory} (${mode})"
    else
      die "${label} is world-writable: ${directory} (${mode})"
    fi
  fi

  if (( EUID == 0 )); then
    owner=$(stat_uid "${directory}")
    if [[ "${owner}" != 0 ]]; then
      if [[ "${ALLOW_INSECURE_INSTALL_DIR}" == 1 ]]; then
        warn "${label} is not owned by root: ${directory} (uid ${owner})"
      else
        die "${label} must be owned by root when installer runs as root: ${directory}"
      fi
    fi
  fi

  [[ -w "${directory}" ]] || die "${label} is not writable: ${directory}"
}

curl_supports() {
  curl --help all 2>/dev/null | grep -Fq -- "$1"
}

download_https() {
  local url=$1 destination=$2 cache_key=$3
  local partial cache_path=""
  local -a curl_args

  [[ "${url}" == https://* ]] || die "refusing non-HTTPS URL: ${url}"
  [[ ! "${url}" =~ [[:cntrl:]] ]] || die "URL contains control characters"

  if [[ -n "${DOWNLOAD_CACHE_DIR}" ]]; then
    validate_directory_security "${DOWNLOAD_CACHE_DIR}" "DOWNLOAD_CACHE_DIR"
    [[ "${cache_key}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid cache key: ${cache_key}"
    cache_path="${DOWNLOAD_CACHE_DIR%/}/${cache_key}"
    if [[ -f "${cache_path}" && ! -L "${cache_path}" ]]; then
      cp -- "${cache_path}" "${destination}"
      return 0
    fi
  fi

  [[ "${OFFLINE}" == 0 ]] || die "offline mode: cache miss for ${cache_key}"

  partial="${destination}.part"
  rm -f -- "${partial}"

  curl_args=(
    --fail
    --silent
    --show-error
    --location
    --proto '=https'
    --proto-redir '=https'
    --tlsv1.2
    --connect-timeout "${CURL_CONNECT_TIMEOUT}"
    --max-time "${CURL_MAX_TIME}"
    --retry "${CURL_RETRIES}"
    --retry-delay 1
    --retry-max-time "${CURL_MAX_TIME}"
    --user-agent "${HTTP_USER_AGENT}"
    --output "${partial}"
  )
  if curl_supports '--retry-all-errors'; then
    curl_args+=(--retry-all-errors)
  fi

  log "downloading ${url}"
  curl "${curl_args[@]}" -- "${url}"
  [[ -s "${partial}" ]] || die "downloaded file is empty: ${url}"
  mv -f -- "${partial}" "${destination}"

  if [[ -n "${cache_path}" ]]; then
    local cache_partial
    cache_partial=$(mktemp "${DOWNLOAD_CACHE_DIR%/}/.${cache_key}.tmp.XXXXXXXX")
    cp -- "${destination}" "${cache_partial}"
    chmod 0644 "${cache_partial}"
    mv -f -- "${cache_partial}" "${cache_path}"
  fi
}

file_size() {
  if stat -c '%s' "$1" >/dev/null 2>&1; then
    stat -c '%s' "$1"
  else
    stat -f '%z' "$1"
  fi
}

assert_max_size() {
  local file=$1 max_bytes=$2 actual
  actual=$(file_size "${file}")
  (( actual <= max_bytes )) ||
    die "download exceeds size limit: ${file} (${actual} > ${max_bytes} bytes)"
}

sha256_file() {
  sha256sum "$1" | awk '{print tolower($1)}'
}

extract_sha256() {
  local checksum_file=$1 asset_name=${2:-} result

  result=$(awk -v asset="${asset_name}" '
    function clean(value) {
      sub(/^\*/, "", value)
      sub(/^\.\//, "", value)
      sub(/:$/, "", value)
      return value
    }
    {
      asset_seen = (asset == "")
      for (i = 1; i <= NF; i++) {
        token = clean($i)
        if (token == asset) asset_seen = 1
      }
      if (asset_seen) {
        for (i = 1; i <= NF; i++) {
          token = clean($i)
          lower = tolower(token)
          if (length(lower) == 64 && lower !~ /[^0-9a-f]/) {
            print lower
            exit
          }
        }
      }
    }
  ' "${checksum_file}")

  if [[ -z "${result}" && -n "${asset_name}" ]]; then
    result=$(awk '
      {
        for (i = 1; i <= NF; i++) {
          token = tolower($i)
          sub(/^\*/, "", token)
          sub(/:$/, "", token)
          if (length(token) == 64 && token !~ /[^0-9a-f]/) {
            hashes[token] = 1
          }
        }
      }
      END {
        count = 0
        for (hash in hashes) {
          count++
          selected = hash
        }
        if (count == 1) print selected
      }
    ' "${checksum_file}")
  fi

  [[ -n "${result}" ]] || die "could not extract SHA-256 for ${asset_name:-artifact}"
  validate_sha256 "${asset_name:-artifact}" "${result}"
  printf '%s\n' "${result}"
}

checksum_pin() {
  local label=$1 fallback=$2 variable
  variable="${label}_SHA256_${ARCH^^}"
  printf '%s\n' "${!variable:-${fallback}}"
}

resolve_checksum() {
  local label=$1 explicit=$2 checksum_url=$3 asset_name=$4 cache_key=$5
  local checksum_file

  if [[ -n "${explicit}" ]]; then
    validate_sha256 "${label}" "${explicit}"
    printf '%s\n' "${explicit,,}"
    return 0
  fi

  [[ "${CHECKSUM_POLICY}" == remote ]] ||
    die "CHECKSUM_POLICY=pinned requires ${label}_SHA256"

  checksum_file="${TMP_ROOT}/${cache_key}"
  download_https "${checksum_url}" "${checksum_file}" "${cache_key}"
  assert_max_size "${checksum_file}" 1048576
  extract_sha256 "${checksum_file}" "${asset_name}"
}

verify_sha256() {
  local file=$1 expected=$2 actual
  actual=$(sha256_file "${file}")
  [[ "${actual}" == "${expected,,}" ]] ||
    die "SHA-256 mismatch for ${file}: expected ${expected,,}, got ${actual}"
  log "verified SHA-256 for ${file##*/}"
}

assert_safe_tar_gz() {
  local archive=$1 member normalized listing type count=0

  while IFS= read -r member; do
    ((count += 1))
    (( count <= 256 )) || die "archive has too many members: ${archive}"
    normalized=${member#./}
    [[ -n "${normalized}" ]] || continue
    [[ "${normalized}" != /* ]] || die "archive contains absolute path: ${member}"
    [[ "${normalized}" != ".." && "${normalized}" != ../* && "${normalized}" != */../* && "${normalized}" != */.. ]] ||
      die "archive contains parent traversal: ${member}"
  done < <(tar -tzf "${archive}")

  (( count > 0 )) || die "archive is empty: ${archive}"

  while IFS= read -r listing; do
    type=${listing:0:1}
    case "${type}" in
      -|d) ;;
      *) die "archive contains unsupported entry type '${type}': ${archive}" ;;
    esac
  done < <(tar -tvzf "${archive}")
}

atomic_install() {
  local source=$1 binary_name=$2 target staged
  target="${INSTALL_DIR%/}/${binary_name}"

  [[ -f "${source}" && ! -L "${source}" ]] || die "install source is not a regular file: ${source}"
  [[ ! -L "${target}" ]] || die "refusing to replace symbolic link: ${target}"

  staged=$(mktemp "${INSTALL_DIR%/}/.${binary_name}.tmp.XXXXXXXX")
  install -m 0755 -- "${source}" "${staged}"
  mv -f -- "${staged}" "${target}"
  log "installed ${binary_name} to ${target}"
}

host_arch() {
  local raw
  raw=$(uname -m)
  case "${raw,,}" in
    amd64|x86_64) printf '%s\n' amd64 ;;
    arm64|aarch64) printf '%s\n' arm64 ;;
    ppc64le) printf '%s\n' ppc64le ;;
    s390x) printf '%s\n' s390x ;;
    386|i386|i686) printf '%s\n' 386 ;;
    arm|armv7|armv7l) printf '%s\n' arm ;;
    *) printf '%s\n' unknown ;;
  esac
}

verify_installed_version() {
  local tool=$1 expected=$2 binary output current_host_arch
  binary="${INSTALL_DIR%/}/${tool}"

  case "${VERIFY_EXECUTABLE}" in
    0) warn "skipping executable version check for ${tool}"; return 0 ;;
    1) ;;
    auto)
      current_host_arch=$(host_arch)
      if [[ "${current_host_arch}" != "${ARCH}" ]]; then
        warn "skipping ${tool} execution for cross-platform build (${current_host_arch} -> ${ARCH})"
        return 0
      fi
      ;;
    *) die "VERIFY_EXECUTABLE must be auto, 0, or 1" ;;
  esac

  case "${tool}" in
    kubectl) output=$("${binary}" version --client=true 2>&1) ;;
    kustomize) output=$("${binary}" version 2>&1) ;;
    kind) output=$("${binary}" version 2>&1) ;;
    helm) output=$("${binary}" version --short 2>&1) ;;
    *) die "no version verifier for ${tool}" ;;
  esac

  grep -Fq -- "${expected}" <<<"${output}" ||
    die "${tool} version check failed; expected ${expected}, output: ${output}"
  log "verified ${tool} ${expected}"
}

verify_kubectl_signature() {
  local binary=$1 base_url=$2 signature certificate
  [[ "${KUBECTL_VERIFY_SIGNATURE}" == 1 ]] || return 0

  require_command cosign
  signature="${TMP_ROOT}/kubectl.sig"
  certificate="${TMP_ROOT}/kubectl.cert"
  download_https "${base_url}/kubectl.sig" "${signature}" "kubectl-${KUBECTL_VERSION}-linux-${ARCH}.sig"
  download_https "${base_url}/kubectl.cert" "${certificate}" "kubectl-${KUBECTL_VERSION}-linux-${ARCH}.cert"

  cosign verify-blob "${binary}" \
    --signature "${signature}" \
    --certificate "${certificate}" \
    --certificate-identity 'krel-staging@k8s-releng-prod.iam.gserviceaccount.com' \
    --certificate-oidc-issuer 'https://accounts.google.com' >/dev/null
  log "verified Sigstore signature for kubectl"
}

install_kubectl() {
  local base_url url checksum_url artifact expected
  validate_version kubectl "${KUBECTL_VERSION}"
  case "${ARCH}" in
    386|amd64|arm|arm64|ppc64le|s390x) ;;
    *) die "kubectl is not configured for linux/${ARCH}" ;;
  esac

  base_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}"
  url="${base_url}/kubectl"
  checksum_url="${url}.sha256"
  artifact="${TMP_ROOT}/kubectl-${KUBECTL_VERSION}-linux-${ARCH}"

  download_https "${url}" "${artifact}" "kubectl-${KUBECTL_VERSION}-linux-${ARCH}"
  assert_max_size "${artifact}" 209715200
  expected=$(resolve_checksum KUBECTL "$(checksum_pin KUBECTL "${KUBECTL_SHA256}")" "${checksum_url}" kubectl "kubectl-${KUBECTL_VERSION}-linux-${ARCH}.sha256")
  verify_sha256 "${artifact}" "${expected}"
  verify_kubectl_signature "${artifact}" "${base_url}"
  atomic_install "${artifact}" kubectl
  verify_installed_version kubectl "${KUBECTL_VERSION}"
}

install_kustomize() {
  local numeric asset base_url url checksum_url archive expected extract_dir binary
  validate_version kustomize "${KUSTOMIZE_VERSION}"
  case "${ARCH}" in
    amd64|arm64|ppc64le|s390x) ;;
    *) die "kustomize is not configured for linux/${ARCH}" ;;
  esac

  numeric=${KUSTOMIZE_VERSION#v}
  asset="kustomize_v${numeric}_linux_${ARCH}.tar.gz"
  base_url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/${KUSTOMIZE_VERSION}"
  url="${base_url}/${asset}"
  checksum_url="${base_url}/checksums.txt"
  archive="${TMP_ROOT}/${asset}"

  download_https "${url}" "${archive}" "${asset}"
  assert_max_size "${archive}" 104857600
  expected=$(resolve_checksum KUSTOMIZE "$(checksum_pin KUSTOMIZE "${KUSTOMIZE_SHA256}")" "${checksum_url}" "${asset}" "kustomize-${KUSTOMIZE_VERSION}-checksums.txt")
  verify_sha256 "${archive}" "${expected}"
  assert_safe_tar_gz "${archive}"

  extract_dir="${TMP_ROOT}/kustomize-extract"
  mkdir -m 0700 -- "${extract_dir}"
  tar -xzf "${archive}" -C "${extract_dir}"
  binary="${extract_dir}/kustomize"
  [[ -f "${binary}" && ! -L "${binary}" ]] || die "kustomize archive did not contain a regular kustomize binary"
  atomic_install "${binary}" kustomize
  verify_installed_version kustomize "${KUSTOMIZE_VERSION}"
}

install_kind() {
  local asset base_url url checksum_url artifact expected
  validate_version kind "${KIND_VERSION}"
  case "${ARCH}" in
    amd64|arm64) ;;
    *) die "kind publishes Linux binaries only for amd64 and arm64; got ${ARCH}" ;;
  esac

  asset="kind-linux-${ARCH}"
  base_url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"
  url="${base_url}/${asset}"
  checksum_url="${base_url}/${asset}.sha256sum"
  artifact="${TMP_ROOT}/${asset}"

  download_https "${url}" "${artifact}" "${asset}-${KIND_VERSION}"
  assert_max_size "${artifact}" 104857600
  expected=$(resolve_checksum KIND "$(checksum_pin KIND "${KIND_SHA256}")" "${checksum_url}" "${asset}" "${asset}-${KIND_VERSION}.sha256sum")
  verify_sha256 "${artifact}" "${expected}"
  atomic_install "${artifact}" kind
  verify_installed_version kind "${KIND_VERSION}"
}

install_helm() {
  local asset url checksum_url archive expected extract_dir binary
  validate_version helm "${HELM_VERSION}"
  case "${ARCH}" in
    386|amd64|arm|arm64|ppc64le|s390x) ;;
    *) die "helm is not configured for linux/${ARCH}" ;;
  esac

  asset="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  url="https://get.helm.sh/${asset}"
  checksum_url="${url}.sha256"
  archive="${TMP_ROOT}/${asset}"

  download_https "${url}" "${archive}" "${asset}"
  assert_max_size "${archive}" 104857600
  expected=$(resolve_checksum HELM "$(checksum_pin HELM "${HELM_SHA256}")" "${checksum_url}" "${asset}" "${asset}.sha256")
  verify_sha256 "${archive}" "${expected}"
  assert_safe_tar_gz "${archive}"

  extract_dir="${TMP_ROOT}/helm-extract"
  mkdir -m 0700 -- "${extract_dir}"
  tar -xzf "${archive}" -C "${extract_dir}"
  binary="${extract_dir}/linux-${ARCH}/helm"
  [[ -f "${binary}" && ! -L "${binary}" ]] || die "helm archive did not contain a regular helm binary"
  atomic_install "${binary}" helm
  verify_installed_version helm "${HELM_VERSION}"
}

main() {
  local -a selected_tools=()
  local tool raw_tools
  declare -A seen=()

  if (($# > 0)); then
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --list) printf '%s\n' kubectl kustomize kind helm; exit 0 ;;
    esac
    selected_tools=("$@")
  else
    raw_tools=${TOOLS//,/ }
    IFS=' ' read -r -a selected_tools <<<"${raw_tools}"
  fi

  ((${#selected_tools[@]} > 0)) || die "no tools selected"

  validate_boolean OFFLINE "${OFFLINE}"
  validate_boolean ALLOW_INSECURE_INSTALL_DIR "${ALLOW_INSECURE_INSTALL_DIR}"
  validate_boolean KUBECTL_VERIFY_SIGNATURE "${KUBECTL_VERIFY_SIGNATURE}"
  case "${VERIFY_EXECUTABLE}" in auto|0|1) ;; *) die "VERIFY_EXECUTABLE must be auto, 0, or 1" ;; esac
  validate_uint CURL_CONNECT_TIMEOUT "${CURL_CONNECT_TIMEOUT}" 1
  validate_uint CURL_MAX_TIME "${CURL_MAX_TIME}" 1
  validate_uint CURL_RETRIES "${CURL_RETRIES}" 0
  validate_no_control_chars HTTP_USER_AGENT "${HTTP_USER_AGENT}"
  case "${CHECKSUM_POLICY}" in
    remote|pinned) ;;
    *) die "CHECKSUM_POLICY must be remote or pinned" ;;
  esac

  require_command awk
  require_command chmod
  require_command cp
  require_command curl
  require_command grep
  require_command install
  require_command mkdir
  require_command mktemp
  require_command mv
  require_command rm
  require_command sha256sum
  require_command stat
  require_command tar
  require_command uname

  normalize_platform
  validate_directory_security "${INSTALL_DIR}" INSTALL_DIR
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/k8s-tools.XXXXXXXX")
  chmod 0700 "${TMP_ROOT}"

  log "target platform: linux/${ARCH}"
  log "checksum policy: ${CHECKSUM_POLICY}"

  for tool in "${selected_tools[@]}"; do
    [[ -n "${tool}" ]] || continue
    [[ "${tool}" =~ ^[a-z0-9-]+$ ]] || die "invalid tool name: ${tool}"
    [[ -z "${seen[${tool}]:-}" ]] || continue
    seen[${tool}]=1

    if [[ "${CHECKSUM_POLICY}" == pinned ]]; then
      local selected_pin
      case "${tool}" in
        kubectl) selected_pin=$(checksum_pin KUBECTL "${KUBECTL_SHA256}") ;;
        kustomize) selected_pin=$(checksum_pin KUSTOMIZE "${KUSTOMIZE_SHA256}") ;;
        kind) selected_pin=$(checksum_pin KIND "${KIND_SHA256}") ;;
        helm) selected_pin=$(checksum_pin HELM "${HELM_SHA256}") ;;
      esac
      [[ -n "${selected_pin}" ]] || die "CHECKSUM_POLICY=pinned requires a ${tool} SHA-256 pin for ${ARCH}"
      validate_sha256 "${tool}" "${selected_pin}"
    fi

    case "${tool}" in
      kubectl) install_kubectl ;;
      kustomize) install_kustomize ;;
      kind) install_kind ;;
      helm) install_helm ;;
      *) die "unsupported tool: ${tool}" ;;
    esac
  done

  log "installation complete"
}

main "$@"
