#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
umask 022

readonly DEFAULT_KUBECTL_VERSION="v1.36.1"
readonly DEFAULT_KUSTOMIZE_VERSION="v5.8.1"
readonly DEFAULT_KIND_VERSION="v0.32.0"
readonly DEFAULT_HELM_VERSION="v4.2.0"

readonly KUBECTL_VERSION="${KUBECTL_VERSION:-${DEFAULT_KUBECTL_VERSION}}"
readonly KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-${DEFAULT_KUSTOMIZE_VERSION}}"
readonly KIND_VERSION="${KIND_VERSION:-${DEFAULT_KIND_VERSION}}"
readonly HELM_VERSION="${HELM_VERSION:-${DEFAULT_HELM_VERSION}}"
readonly TARGETOS="${TARGETOS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
readonly TARGETARCH="${TARGETARCH:-$(uname -m)}"
readonly INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
readonly TOOLS="${TOOLS:-kubectl,kustomize,kind,helm}"

readonly CURL_OPTIONS=(
  --connect-timeout 15
  --fail
  --location
  --proto '=https'
  --proto-redir '=https'
  --retry 5
  --retry-all-errors
  --retry-delay 2
  --show-error
  --silent
  --tlsv1.2
)

TMP_DIR=""
OS=""
ARCH=""

log() {
  printf '[bootstrap] %s\n' "$*" >&2
}

fail() {
  printf '[bootstrap] error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
}
trap cleanup EXIT INT TERM HUP

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

validate_version() {
  local tool="$1"
  local version="$2"

  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] \
    || fail "invalid ${tool} version: ${version}"
}

normalize_platform() {
  case "${TARGETOS}" in
    linux) OS=linux ;;
    *) fail "unsupported target operating system: ${TARGETOS}" ;;
  esac

  case "${TARGETARCH}" in
    amd64|x86_64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) fail "unsupported target architecture: ${TARGETARCH}" ;;
  esac
}

validate_install_dir() {
  [[ "${INSTALL_DIR}" == /* ]] || fail "INSTALL_DIR must be an absolute path"
  mkdir -p -- "${INSTALL_DIR}"
  [[ -d "${INSTALL_DIR}" && -w "${INSTALL_DIR}" ]] \
    || fail "INSTALL_DIR is not writable: ${INSTALL_DIR}"
}

download() {
  local url="$1"
  local output="$2"

  log "downloading ${url}"
  curl "${CURL_OPTIONS[@]}" --output "${output}" -- "${url}"
  [[ -s "${output}" ]] || fail "downloaded file is empty: ${url}"
}

read_sha256() {
  local checksum_file="$1"
  local asset_name="${2:-}"
  local checksum=""

  if [[ -n "${asset_name}" ]]; then
    checksum="$({ awk -v name="${asset_name}" '$2 == name || $2 == "*" name {print $1; exit}' "${checksum_file}"; } || true)"
    [[ -n "${checksum}" ]] \
      || fail "checksum manifest does not contain asset: ${asset_name}"
  else
    checksum="$(awk 'NF {print $1; exit}' "${checksum_file}")"
  fi

  [[ "${checksum}" =~ ^[0-9A-Fa-f]{64}$ ]] \
    || fail "invalid SHA-256 checksum in ${checksum_file}"
  printf '%s\n' "${checksum,,}"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] \
    || fail "checksum mismatch for $(basename "${file}"): expected ${expected}, got ${actual}"
}

install_binary() {
  local source="$1"
  local name="$2"

  [[ -f "${source}" ]] || fail "binary not found after extraction: ${source}"
  install -m 0755 -- "${source}" "${INSTALL_DIR}/${name}"
  log "installed ${name} to ${INSTALL_DIR}/${name}"
}

install_kubectl() {
  local base_url asset checksum_file expected

  asset="kubectl"
  base_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}"
  checksum_file="${TMP_DIR}/${asset}.sha256"

  download "${base_url}/${asset}" "${TMP_DIR}/${asset}"
  if [[ -n "${KUBECTL_SHA256:-}" ]]; then
    expected="${KUBECTL_SHA256,,}"
  else
    download "${base_url}/${asset}.sha256" "${checksum_file}"
    expected="$(read_sha256 "${checksum_file}")"
  fi
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid KUBECTL_SHA256"
  verify_sha256 "${TMP_DIR}/${asset}" "${expected}"
  install_binary "${TMP_DIR}/${asset}" kubectl
}

install_kind() {
  local base_url asset checksum_file expected

  asset="kind-${OS}-${ARCH}"
  base_url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"
  checksum_file="${TMP_DIR}/${asset}.sha256sum"

  download "${base_url}/${asset}" "${TMP_DIR}/${asset}"
  if [[ -n "${KIND_SHA256:-}" ]]; then
    expected="${KIND_SHA256,,}"
  else
    download "${base_url}/${asset}.sha256sum" "${checksum_file}"
    expected="$(read_sha256 "${checksum_file}" "${asset}")"
  fi
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid KIND_SHA256"
  verify_sha256 "${TMP_DIR}/${asset}" "${expected}"
  install_binary "${TMP_DIR}/${asset}" kind
}

install_kustomize() {
  local base_url asset archive checksum_file expected extract_dir

  asset="kustomize_${KUSTOMIZE_VERSION}_${OS}_${ARCH}.tar.gz"
  base_url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}"
  archive="${TMP_DIR}/${asset}"
  checksum_file="${TMP_DIR}/checksums.txt"
  extract_dir="${TMP_DIR}/kustomize"

  download "${base_url}/${asset}" "${archive}"
  if [[ -n "${KUSTOMIZE_SHA256:-}" ]]; then
    expected="${KUSTOMIZE_SHA256,,}"
  else
    download "${base_url}/checksums.txt" "${checksum_file}"
    expected="$(read_sha256 "${checksum_file}" "${asset}")"
  fi
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid KUSTOMIZE_SHA256"
  verify_sha256 "${archive}" "${expected}"

  mkdir -p -- "${extract_dir}"
  tar --extract --gzip --file "${archive}" --directory "${extract_dir}" --no-same-owner
  install_binary "${extract_dir}/kustomize" kustomize
}

install_helm() {
  local version_without_v base_url asset archive checksum_file expected extract_dir

  version_without_v="${HELM_VERSION#v}"
  asset="helm-v${version_without_v}-${OS}-${ARCH}.tar.gz"
  base_url="https://get.helm.sh"
  archive="${TMP_DIR}/${asset}"
  checksum_file="${TMP_DIR}/${asset}.sha256sum"
  extract_dir="${TMP_DIR}/helm"

  download "${base_url}/${asset}" "${archive}"
  if [[ -n "${HELM_SHA256:-}" ]]; then
    expected="${HELM_SHA256,,}"
  else
    download "${base_url}/${asset}.sha256sum" "${checksum_file}"
    expected="$(read_sha256 "${checksum_file}" "${asset}")"
  fi
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid HELM_SHA256"
  verify_sha256 "${archive}" "${expected}"

  mkdir -p -- "${extract_dir}"
  tar --extract --gzip --file "${archive}" --directory "${extract_dir}" --no-same-owner
  install_binary "${extract_dir}/${OS}-${ARCH}/helm" helm
}

install_requested_tools() {
  local normalized tool
  local -a requested=()
  declare -A seen=()

  normalized="${TOOLS//,/ }"
  read -r -a requested <<< "${normalized}"
  (( ${#requested[@]} > 0 )) || fail "TOOLS must select at least one tool"

  for tool in "${requested[@]}"; do
    [[ -n "${tool}" ]] || continue
    [[ -z "${seen[${tool}]:-}" ]] || continue
    seen["${tool}"]=1

    case "${tool}" in
      kubectl) install_kubectl ;;
      kustomize) install_kustomize ;;
      kind) install_kind ;;
      helm) install_helm ;;
      *) fail "unsupported tool in TOOLS: ${tool}" ;;
    esac
  done
}

main() {
  require_command curl
  require_command install
  require_command mktemp
  require_command sha256sum
  require_command tar

  validate_version kubectl "${KUBECTL_VERSION}"
  validate_version kustomize "${KUSTOMIZE_VERSION}"
  validate_version kind "${KIND_VERSION}"
  validate_version helm "${HELM_VERSION}"
  normalize_platform
  validate_install_dir

  TMP_DIR="$(mktemp -d)"
  [[ -d "${TMP_DIR}" ]] || fail "unable to create temporary directory"

  install_requested_tools
}

main "$@"
