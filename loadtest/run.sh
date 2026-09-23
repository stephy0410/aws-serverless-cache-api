#!/usr/bin/env bash
# Benchmark suite: same constant request rate against the uncached and cached
# paths, a mixed read/write run, and a step test that keeps raising the rate.
#
# wrk2 holds the request rate constant (-R) and corrects for coordinated
# omission, so the latency percentiles reflect what users would actually see.
#
# Usage: loadtest/run.sh https://<alb-dns>
#   RATE=100 DURATION=30s CONNECTIONS=50 THREADS=2 STEPS="25 50 100" loadtest/run.sh ...
#   ONLY=top TOP_RATE=50 loadtest/run.sh ...   (just the heavy-query comparison)
set -euo pipefail

URL="${1:?usage: $0 https://<alb-dns>}"
URL="${URL%/}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WRK="$HERE/.wrk2/wrk"

RATE="${RATE:-100}"
DURATION="${DURATION:-30s}"
# Rates are kept low on purpose: AWS Academy deactivated the account during a run at up to
# 1000 req/s. Over a ~100 ms round trip each connection sustains ~10 req/s, so 50 is plenty here.
CONNECTIONS="${CONNECTIONS:-50}"
THREADS="${THREADS:-2}"
STEPS="${STEPS:-25 50 100}"
STEP_DURATION="${STEP_DURATION:-20s}"
TOP_RATE="${TOP_RATE:-50}"
# ONLY=top runs just the heavy-query comparison (scenarios 5-6).
ONLY="${ONLY:-}"

ulimit -n 4096 2>/dev/null || true

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

# 0. Warm-up (not measured). Provisioned concurrency is blocked in AWS Academy, so
#    ramp the rate gradually: Lambda creates execution environments a few at a time
#    instead of a burst of cold starts all at once, which would hit reserved concurrency and throttle.
echo "=== warm-up: ramping Lambda execution environments ==="
for rate in 10 25 50 100; do
  "$WRK" -t"$THREADS" -c"$CONNECTIONS" -d10s -R"$rate" "$URL/health" >/dev/null
done
echo

if [[ "$ONLY" != "top" ]]; then
  # 1. Every read goes to RDS: the baseline.
  run 1-no-cache "$RATE" "$DURATION" PATH_PREFIX=/db/products

  # 2. Same traffic through cache-aside (starts cold if the last run was > TTL ago, so it includes the fill-up misses).
  run 2-cache-aside "$RATE" "$DURATION" PATH_PREFIX=/products

  # 3. 95% reads / 5% writes: every write invalidates a key that is then re-read from RDS.
  run 3-mixed-95r-5w "$RATE" "$DURATION" PATH_PREFIX=/products WRITE_RATIO=0.05

  # 4. Step test: raise the rate and check that latency stays flat.
  for step in $STEPS; do
    run "4-step-${step}rps" "$step" "$STEP_DURATION" PATH_PREFIX=/products
  done
fi

# 5-6. The heavy query (top 10 per category aggregates every review, ~50 ms in RDS vs ~2 ms
#      from the cache). A single product lookup is too cheap to ever make the database the
#      bottleneck; this one does, so it is where the cache makes the difference in capacity.
run 5-top-no-cache "$TOP_RATE" "$DURATION" PATH_PREFIX=/db/products MODE=top
run 6-top-cache "$TOP_RATE" "$DURATION" PATH_PREFIX=/products MODE=top

curl -sk "$URL/stats" | tee "$OUT/cache-stats.json"
echo
echo "Results saved in $OUT"
