#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

if (( $# == 0 )); then
  exec /bin/bash
fi

# Backward compatibility for the former kind-only image and existing Make targets.
case "$1" in
  build|completion|create|delete|export|get|load|version)
    exec kind "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
