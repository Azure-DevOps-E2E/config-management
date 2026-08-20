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

py_bin="$(command -v python3 || command -v python || true)"
if [[ -z "$py_bin" ]]; then
  echo 'python3 is required for JSON parsing' >&2
  exit 1
fi

json_get() {
  local key="$1"
  local json="$2"
  "$py_bin" -c 'import json, sys
key = sys.argv[1]
data = json.loads(sys.argv[2])
value = data
for part in key.split("."):
    value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)' "$key" "$json"
}

assert_true() {
  local condition="$1"
  local message="$2"
  if ! eval "$condition"; then
    echo "$message" >&2
    exit 1
  fi
}

base="${base_url%/}"
health_checks=(
  '/health/api-gateway|api-gateway'
  '/health/frontend|frontend'
  '/health/user-service|user-service'
  '/health/catalog-service|catalog-service'
  '/health/order-service|order-service'
)

printf '%s\n' 'Checking service health and versions...'
for check in "${health_checks[@]}"; do
  IFS='|' read -r path service <<< "$check"
  health_json="$(curl -fsS --max-time 5 "$base$path")"
  status="$(json_get 'status' "$health_json")"
  reported_service="$(json_get 'service' "$health_json")"
  version="$(json_get 'version' "$health_json")"
  assert_true "[[ \"$status\" == 'UP' ]]" "$service is not healthy"
  assert_true "[[ \"$reported_service\" == '$service' ]]" "$service returned an unexpected service name"
  assert_true "[[ -n \"$version\" && \"$version\" != 'null' ]]" "$service did not report a version"
done

printf '%s\n' 'Reading users and products through the gateway...'
users_json="$(curl -fsS --max-time 10 "$base/api/v1/users")"
products_json="$(curl -fsS --max-time 10 "$base/api/v1/products")"
user_count="$(json_get 'items' "$users_json" | "$py_bin" -c 'import json, sys; print(len(json.load(sys.stdin)))')"
product_count="$(json_get 'items' "$products_json" | "$py_bin" -c 'import json, sys; print(len(json.load(sys.stdin)))')"
assert_true "[[ $user_count -gt 0 ]]" 'User seed data is missing'
assert_true "[[ $product_count -gt 0 ]]" 'Product seed data is missing'

user_id="$(json_get 'items' "$users_json" | "$py_bin" -c 'import json, sys; print(json.load(sys.stdin)[0]["id"])')"
product_id="$(json_get 'items' "$products_json" | "$py_bin" -c 'import json, sys; print(json.load(sys.stdin)[0]["id"])')"
payload="$($py_bin -c 'import json, sys; print(json.dumps({"userId": sys.argv[1], "items": [{"productId": sys.argv[2], "quantity": 2}]}))' "$user_id" "$product_id")"

printf '%s\n' 'Creating an order...'
order_json="$(curl -fsS --max-time 10 -X POST "$base/api/v1/orders" -H 'Content-Type: application/json' -d "$payload")"
order_id="$(json_get 'id' "$order_json")"
order_total="$(json_get 'totalAmount' "$order_json")"
assert_true "[[ \"$order_id\" == ord-* ]]" 'Order ID has an unexpected format'
assert_true "[[ $order_total -gt 0 ]]" 'Order total was not calculated'

printf '%s\n' 'Reading the created order...'
saved_order_json="$(curl -fsS --max-time 10 "$base/api/v1/orders/$order_id")"
saved_order_id="$(json_get 'id' "$saved_order_json")"
assert_true "[[ \"$saved_order_id\" == \"$order_id\" ]]" 'Created order cannot be read back'

printf 'Smoke test passed: %s, total %s VND\n' "$order_id" "$order_total"