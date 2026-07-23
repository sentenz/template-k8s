#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

case "${1:-}" in
  kubectl|kustomize|kind|helm)
    exec "$@"
    ;;
  "")
    exec kind version
    ;;
  *)
    # Backward compatibility for the former kind-only image: unqualified
    # arguments remain kind subcommands, while explicit tool names dispatch
    # directly to the selected executable.
    exec kind "$@"
    ;;
esac
