#!/usr/bin/env bash
set -euo pipefail

base_url='http://localhost:8080'

while [[ $# -gt 0 ]]; do
  case "$1" in
    -BaseUrl|--base-url)
      base_url="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$script_dir/health.sh" -BaseUrl "$base_url"
bash "$script_dir/smoke.sh" -BaseUrl "$base_url"