#!/usr/bin/env bash
set -euo pipefail

base_url='http://localhost:8080'
expected_service=''
expected_version=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    -BaseUrl|--base-url)
      base_url="${2:-}"
      shift 2
      ;;
    -ExpectedService|--expected-service)
      expected_service="${2:-}"
      shift 2
      ;;
    -ExpectedVersion|--expected-version)
      expected_version="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if { [[ -z "$expected_service" ]] && [[ -n "$expected_version" ]]; } || { [[ -n "$expected_service" ]] && [[ -z "$expected_version" ]]; }; then
  echo 'ExpectedService and ExpectedVersion must be provided together' >&2
  exit 1
fi

py_bin="$(command -v python3 || command -v python || true)"
if [[ -z "$py_bin" ]]; then
  echo 'python3 is required for JSON parsing' >&2
  exit 1
fi

base="${base_url%/}"
checks=(
  'API Gateway|/health/api-gateway|api-gateway'
  'Frontend|/health/frontend|frontend'
  'User Service|/health/user-service|user-service'
  'Catalog Service|/health/catalog-service|catalog-service'
  'Order Service|/health/order-service|order-service'
)

if [[ -n "$expected_service" ]]; then
  case "$expected_service" in
    api-gateway|frontend|user-service|catalog-service|order-service) ;;
    *)
      echo "Unknown expected service: $expected_service" >&2
      exit 1
      ;;
  esac
fi

printf '%-16s %-8s %-12s %-10s %s\n' 'Component' 'Status' 'Version' 'Latency' 'Detail'

failed=0
for check in "${checks[@]}"; do
  IFS='|' read -r name path service <<< "$check"
  start_ms="$($py_bin -c 'import time; print(int(time.time() * 1000))')"
  if response="$(curl -fsS --max-time 5 "$base$path" 2>&1)"; then
    end_ms="$($py_bin -c 'import time; print(int(time.time() * 1000))')"
    status="$($py_bin -c 'import json, sys; print(json.loads(sys.argv[1]).get("status", ""))' "$response")"
    reported_service="$($py_bin -c 'import json, sys; print(json.loads(sys.argv[1]).get("service", ""))' "$response")"
    reported_version="$($py_bin -c 'import json, sys; print(json.loads(sys.argv[1]).get("version", "unknown"))' "$response")"
    latency_ms=$((end_ms - start_ms))
    detail='OK'

    if [[ "$status" != 'UP' || "$reported_service" != "$service" ]]; then
      status='DOWN'
      detail='Unexpected health response'
      failed=1
    elif [[ -n "$expected_service" && "$service" == "$expected_service" && "$reported_version" != "$expected_version" ]]; then
      status='DOWN'
      detail="Expected version $expected_version, got $reported_version"
      failed=1
    fi
  else
    end_ms="$($py_bin -c 'import time; print(int(time.time() * 1000))')"
    latency_ms=$((end_ms - start_ms))
    status='DOWN'
    reported_version='unknown'
    detail="$response"
    failed=1
  fi

  printf '%-16s %-8s %-12s %-10s %s\n' "$name" "$status" "$reported_version" "${latency_ms}ms" "$detail"
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi