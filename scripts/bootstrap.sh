#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
umask 022

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly INSTALLER="${SCRIPT_DIR}/install-tools.sh"

fail() {
  printf '[bootstrap] error: %s\n' "$*" >&2
  exit 1
}

select_install_dir() {
  if [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    printf '%s\n' /usr/local/bin
    return
  fi

  [[ -n "${HOME:-}" ]] || fail 'HOME is not set and /usr/local/bin is not writable'
  printf '%s\n' "${HOME}/.local/bin"
}

ensure_path() {
  local install_dir="$1"
  local shell_rc

  case ":${PATH}:" in
    *":${install_dir}:"*) return ;;
  esac

  export PATH="${install_dir}:${PATH}"
  [[ -n "${HOME:-}" ]] || return

  shell_rc="${HOME}/.profile"
  if [[ -n "${BASH_VERSION:-}" ]]; then
    shell_rc="${HOME}/.bashrc"
  fi

  if ! grep -qF "${install_dir}" "${shell_rc}" 2>/dev/null; then
    {
      printf '\n# Added by template-k8s bootstrap\n'
      printf 'export PATH="%s:$PATH"\n' "${install_dir}"
    } >> "${shell_rc}"
  fi
}

main() {
  local install_dir

  [[ -f "${INSTALLER}" ]] || fail "installer not found: ${INSTALLER}"
  install_dir="${INSTALL_DIR:-$(select_install_dir)}"
  mkdir -p -- "${install_dir}"

  INSTALL_DIR="${install_dir}" bash "${INSTALLER}"
  ensure_path "${install_dir}"

  kubectl version --client=true --output=yaml
  kustomize version
  kind version
  helm version --short
}

main "$@"
