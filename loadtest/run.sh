#!/usr/bin/env bash
# Benchmark suite: same constant request rate against the uncached and cached
# paths, a mixed read/write run, and a step test that keeps raising the rate.
#
# wrk2 holds the request rate constant (-R) and corrects for coordinated
# omission, so the latency percentiles reflect what users would actually see.
#
# Usage: loadtest/run.sh https://<alb-dns>
#   RATE=500 DURATION=60s CONNECTIONS=100 THREADS=4 STEPS="250 500 1000 1500" loadtest/run.sh ...
set -euo pipefail

URL="${1:?usage: $0 https://<alb-dns>}"
URL="${URL%/}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WRK="$HERE/.wrk2/wrk"

RATE="${RATE:-500}"
DURATION="${DURATION:-60s}"
CONNECTIONS="${CONNECTIONS:-100}"
THREADS="${THREADS:-4}"
STEPS="${STEPS:-250 500 1000 1500}"
STEP_DURATION="${STEP_DURATION:-30s}"

OUT="$HERE/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

[[ -x "$WRK" ]] || "$HERE/build-wrk2.sh"

run() {
  local name="$1" rate="$2" duration="$3"
  shift 3
  echo "=== $name  (${rate} req/s for ${duration}) ==="
  env "$@" "$WRK" -t"$THREADS" -c"$CONNECTIONS" -d"$duration" -R"$rate" --latency \
    -s "$HERE/catalog.lua" "$URL" | tee "$OUT/$name.txt"
  echo
}

curl -skf "$URL/health" >/dev/null || { echo "API not healthy at $URL/health" >&2; exit 1; }

# 1. Every read goes to RDS: the baseline.
run 1-no-cache "$RATE" "$DURATION" PATH_PREFIX=/db/products

# 2. Same traffic through cache-aside (starts cold, so includes the warm-up misses).
run 2-cache-aside "$RATE" "$DURATION" PATH_PREFIX=/products

# 3. 95% reads / 5% writes: every write invalidates a key that is then re-read from RDS.
run 3-mixed-95r-5w "$RATE" "$DURATION" PATH_PREFIX=/products WRITE_RATIO=0.05

# 4. Step test: raise the rate and check that latency stays flat.
for step in $STEPS; do
  run "4-step-${step}rps" "$step" "$STEP_DURATION" PATH_PREFIX=/products
done

curl -sk "$URL/stats" | tee "$OUT/cache-stats.json"
echo
echo "Results saved in $OUT"
