#!/usr/bin/env bash
# Source from Bash on an operator host or runner with a trusted root file.
sigstore_client() {
  local anchor=$1 cache
  cache=$(mktemp -d) || return
  export TUF_ROOT="$cache" TUF_MIRROR=https://tuf.sigstore.local TUF_ROOT_JSON="$anchor"
  if ! cosign initialize --mirror "$TUF_MIRROR" --root "$anchor"; then
    rm -rf -- "$cache"
    return 1
  fi
  local -a roots configs
  mapfile -t roots < <(find "$cache" -type f -path '*/targets/trusted_root.json')
  mapfile -t configs < <(find "$cache" -type f -path '*/targets/signing_config.v0.2.json')
  if [[ ${#roots[@]} != 1 || ${#configs[@]} != 1 ]]; then
    echo 'Missing verified private TUF targets' >&2
    rm -rf -- "$cache"
    return 1
  fi
  export SIGSTORE_TRUSTED_ROOT="${roots[0]}" SIGSTORE_SIGNING_CONFIG="${configs[0]}"
}
