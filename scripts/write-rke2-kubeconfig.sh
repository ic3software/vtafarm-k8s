#!/usr/bin/env bash
# Preserve locally renewed credentials instead of overwriting them from state.
set -euo pipefail
[ "$#" -eq 2 ] || { echo 'usage: write-rke2-kubeconfig.sh <cluster-dir> <destination>' >&2; exit 2; }
exec bash "$(dirname "$0")/rke2-kubeconfig.sh" write "$1" "$2"
