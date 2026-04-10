#!/usr/bin/env bash
# =============================================================================
# Tricount Backend — Load Testing Script
#
# Uses curl + bash concurrency to stress-test key API endpoints.
# No external dependencies required.
#
# Usage:
#   ./Scripts/load_test.sh                      # defaults: 50 concurrent, 200 total
#   ./Scripts/load_test.sh -c 100 -n 500        # 100 concurrent, 500 total requests
#   ./Scripts/load_test.sh -u http://host:8080   # custom base URL
#
# Prerequisites: The server must be running (swift run or docker compose up)
# =============================================================================

set -euo pipefail

# --- Defaults ---------------------------------------------------------------
BASE_URL="${BASE_URL:-http://localhost:8080}"
CONCURRENCY=200
TOTAL_REQUESTS=2000

# --- Parse flags ------------------------------------------------------------
while getopts "c:n:u:" opt; do
    case $opt in
        c) CONCURRENCY=$OPTARG ;;
        n) TOTAL_REQUESTS=$OPTARG ;;
        u) BASE_URL=$OPTARG ;;
        *) echo "Usage: $0 [-c concurrency] [-n total_requests] [-u base_url]"; exit 1 ;;
    esac
done

RESULTS_DIR=$(mktemp -d)
trap 'rm -rf "$RESULTS_DIR"' EXIT

echo "========================================"
echo " Tricount Backend Load Test"
echo "========================================"
echo " Base URL:    $BASE_URL"
echo " Concurrency: $CONCURRENCY"
echo " Total:       $TOTAL_REQUESTS"
echo " Results dir: $RESULTS_DIR"
echo "========================================"
echo ""

# --- Helper: fire a single request and record timing ------------------------
fire() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local label="$4"
    local idx="$5"

    local curl_args=(-s -o /dev/null -w "%{http_code} %{time_total}" -X "$method")
    if [ -n "$data" ]; then
        curl_args+=(-H "Content-Type: application/json" -d "$data")
    fi
    if [ -n "${AUTH_TOKEN:-}" ]; then
        curl_args+=(-H "Authorization: Bearer $AUTH_TOKEN")
    fi

    local result
    result=$(curl "${curl_args[@]}" "${BASE_URL}${path}" 2>/dev/null) || result="000 0.000"
    echo "$result" >> "$RESULTS_DIR/${label}.log"
}

# --- Helper: run a load test scenario ---------------------------------------
run_scenario() {
    local label="$1"
    local method="$2"
    local path="$3"
    local data="${4:-}"
    local count="${5:-$TOTAL_REQUESTS}"

    echo "[$label] Sending $count $method requests to $path (concurrency: $CONCURRENCY)..."

    local pids=()
    local running=0

    for i in $(seq 1 "$count"); do
        fire "$method" "$path" "$data" "$label" "$i" &
        pids+=($!)
        running=$((running + 1))

        if [ $running -ge "$CONCURRENCY" ]; then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
            running=$((running - 1))
        fi
    done

    # Wait for remaining
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Summarize
    summarize "$label" "$count"
}

# --- Helper: summarize results (uses python3 for portable float math) -------
summarize() {
    local label="$1"
    local count="$2"
    local file="$RESULTS_DIR/${label}.log"

    if [ ! -f "$file" ]; then
        echo "  [WARN] No results file for $label"
        return
    fi

    python3 - "$file" <<'PYEOF'
import sys

file_path = sys.argv[1]
total_ok = 0
total_err = 0
total_429 = 0
total_time = 0.0
min_time = float("inf")
max_time = 0.0
actual_count = 0

with open(file_path) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        actual_count += 1
        code = int(parts[0].split(".")[0])
        t = float(parts[1])

        if 200 <= code < 400:
            total_ok += 1
        elif code == 429:
            total_429 += 1
        else:
            total_err += 1

        total_time += t
        if t < min_time:
            min_time = t
        if t > max_time:
            max_time = t

if actual_count == 0:
    print("  [WARN] No results recorded")
    sys.exit(0)

avg_time = total_time / actual_count
pct = total_ok * 100.0 / actual_count
rps = actual_count / total_time if total_time > 0 else 0

print(f"  Results:")
print(f"    Requests:    {actual_count}")
print(f"    Success:     {total_ok} ({pct:.1f}%)")
print(f"    Rate-limited: {total_429}")
print(f"    Errors:      {total_err}")
print(f"    Avg latency: {avg_time:.3f}s")
print(f"    Min latency: {min_time:.3f}s")
print(f"    Max latency: {max_time:.3f}s")
print(f"    Throughput:  ~{rps:.1f} req/s (estimated)")
print()
PYEOF
}

# =============================================================================
# Scenarios
# =============================================================================

# 1. Health check (GET /) — should handle high throughput easily
run_scenario "health_check" "GET" "/" "" "$TOTAL_REQUESTS"

# 2. Register a user for authenticated tests
REG_EMAIL="loadtest+$(date +%s)@example.com"
REG_RESP=$(curl -s -X POST "${BASE_URL}/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$REG_EMAIL\",\"password\":\"Password1\",\"displayName\":\"Load Test\"}" 2>/dev/null) || true

AUTH_TOKEN=$(echo "$REG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null) || AUTH_TOKEN=""
REFRESH_TOKEN=$(echo "$REG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('refreshToken',''))" 2>/dev/null) || REFRESH_TOKEN=""

if [ -z "$AUTH_TOKEN" ]; then
    echo "[WARN] Could not register test user — skipping authenticated endpoint tests"
    echo "       Make sure the server is running: swift run"
    echo ""
else
    echo "[setup] Registered test user: $REG_EMAIL"
    echo ""

    # 3. GET /v1/auth/me — authenticated endpoint under load
    run_scenario "get_me" "GET" "/v1/auth/me" "" "$TOTAL_REQUESTS"

    # 4. Login attempts (correct credentials) — includes bcrypt, so slower
    LOGIN_DATA="{\"email\":\"$REG_EMAIL\",\"password\":\"Password1\"}"
    run_scenario "login" "POST" "/v1/auth/login" "$LOGIN_DATA" "$((TOTAL_REQUESTS / 2))"
fi

# 5. Login with invalid credentials — tests error path performance
INVALID_LOGIN="{\"email\":\"nonexistent@example.com\",\"password\":\"Wrong1234\"}"
run_scenario "login_invalid" "POST" "/v1/auth/login" "$INVALID_LOGIN" "$TOTAL_REQUESTS"

# 6. Forgot password — rate-limited endpoint (3/hour), expect 429s
FORGOT_DATA="{\"email\":\"ratelimit-loadtest@example.com\"}"
run_scenario "forgot_password_rate_limit" "POST" "/v1/auth/forgot-password" "$FORGOT_DATA" 20

# 7. Todo list (unauthenticated, lightweight)
unset AUTH_TOKEN
run_scenario "todo_list" "GET" "/v1/todos" "" "$TOTAL_REQUESTS"

echo "========================================"
echo " Load Test Complete"
echo "========================================"
