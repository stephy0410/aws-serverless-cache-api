-- wrk2 workload for the catalog API.
--
-- Traffic is skewed the way real catalogs are: HOT_SHARE of reads go to the
-- first HOT_IDS products, the rest are spread over all MAX_ID products.
-- WRITE_RATIO of requests are PUTs that change a price (and invalidate its cache entry).
--
-- Environment variables:
--   PATH_PREFIX  /products (cache-aside, default) or /db/products (no cache)
--   MAX_ID       10000
--   HOT_IDS      2000
--   HOT_SHARE    0.8
--   WRITE_RATIO  0

local prefix      = os.getenv("PATH_PREFIX") or "/products"
local max_id      = tonumber(os.getenv("MAX_ID") or "10000")
local hot_ids     = tonumber(os.getenv("HOT_IDS") or "2000")
local hot_share   = tonumber(os.getenv("HOT_SHARE") or "0.8")
local write_ratio = tonumber(os.getenv("WRITE_RATIO") or "0")

local threads = {}
local counter = 0

function setup(thread)
  counter = counter + 1
  thread:set("seed", counter)
  table.insert(threads, thread)
end

function init(args)
  math.randomseed(os.time() * 1000 + seed)
  hits, misses, bypass, writes, errors = 0, 0, 0, 0, 0
end

local function pick_id()
  if math.random() < hot_share then
    return math.random(1, hot_ids)
  end
  return math.random(1, max_id)
end

function request()
  local id = pick_id()
  if math.random() < write_ratio then
    local body = string.format('{"price": %.2f}', 5 + math.random() * 495)
    return wrk.format("PUT", "/products/" .. id, { ["Content-Type"] = "application/json" }, body)
  end
  return wrk.format("GET", prefix .. "/" .. id)
end

function response(status, headers, body)
  if status >= 400 then
    errors = errors + 1
    return
  end
  local cache = headers["X-Cache"] or headers["x-cache"]
  if cache == "HIT" then
    hits = hits + 1
  elseif cache == "MISS" then
    misses = misses + 1
  elseif cache == "BYPASS" then
    bypass = bypass + 1
  else
    writes = writes + 1
  end
end

function done(summary, latency, requests)
  local h, m, b, w, e = 0, 0, 0, 0, 0
  for _, t in ipairs(threads) do
    h = h + t:get("hits")
    m = m + t:get("misses")
    b = b + t:get("bypass")
    w = w + t:get("writes")
    e = e + t:get("errors")
  end
  io.write("------------------------------\n")
  io.write(string.format("X-Cache  HIT=%d  MISS=%d  BYPASS=%d  writes=%d  http_errors=%d\n", h, m, b, w, e))
  if h + m > 0 then
    io.write(string.format("Cache hit ratio: %.2f%%\n", 100 * h / (h + m)))
  end
  io.write(string.format("Socket errors: connect=%d read=%d write=%d timeout=%d\n",
    summary.errors.connect, summary.errors.read, summary.errors.write, summary.errors.timeout))
  for _, p in ipairs({ 50, 90, 99, 99.9 }) do
    io.write(string.format("p%-5s %8.2f ms\n", tostring(p), latency:percentile(p) / 1000))
  end
end
