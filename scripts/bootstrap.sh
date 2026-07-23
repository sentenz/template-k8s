#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly INSTALLER="${SCRIPT_DIR}/install-k8s-tools.sh"
readonly DEFAULT_TOOLS="kubectl kustomize kind helm"

: "${K8S_BOOTSTRAP_TOOLS:=${DEFAULT_TOOLS}}"
: "${K8S_BOOTSTRAP_FORCE:=0}"

case "${K8S_BOOTSTRAP_FORCE}" in
  0|1) ;;
  *) printf 'bootstrap.sh: error: K8S_BOOTSTRAP_FORCE must be 0 or 1\n' >&2; exit 1 ;;
esac

[[ -x "${INSTALLER}" ]] || {
  printf 'bootstrap.sh: error: installer is missing or not executable: %s\n' "${INSTALLER}" >&2
  exit 1
}

choose_install_dir() {
  if [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    printf '%s\n' /usr/local/bin
    return
  fi

  [[ -n "${HOME:-}" ]] || {
    printf 'bootstrap.sh: error: HOME is unset and /usr/local/bin is not writable\n' >&2
    exit 1
  }

  local user_bin="${HOME}/.local/bin"
  mkdir -p -- "${user_bin}"
  export PATH="${user_bin}:${PATH}"

  local shell_profile="${HOME}/.bashrc"
  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  if [[ ! -f "${shell_profile}" ]] || ! grep -Fqx -- "${path_line}" "${shell_profile}"; then
    printf '\n# Added by template-k8s bootstrap\n%s\n' "${path_line}" >> "${shell_profile}"
  fi

  printf '%s\n' "${user_bin}"
}

main() {
  local install_dir raw tool
  local -a requested=() selected=()

  install_dir="$(choose_install_dir)"
  raw="${K8S_BOOTSTRAP_TOOLS//,/ }"
  read -r -a requested <<< "${raw}"

  for tool in "${requested[@]}"; do
    [[ -n "${tool}" ]] || continue
    case "${tool}" in
      kubectl|kustomize|kind|helm) ;;
      *) printf 'bootstrap.sh: error: unsupported tool: %s\n' "${tool}" >&2; exit 1 ;;
    esac

    if [[ "${K8S_BOOTSTRAP_FORCE}" == 1 ]] || ! command -v "${tool}" >/dev/null 2>&1; then
      selected+=("${tool}")
    fi
  done

  if ((${#selected[@]} == 0)); then
    printf 'Kubernetes CLI tools are already installed.\n'
    return
  fi

  INSTALL_DIR="${install_dir}" "${INSTALLER}" "${selected[@]}"
}

main "$@"
