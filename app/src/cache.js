// Cache-aside (lazy loading) over ElastiCache (Valkey, Redis protocol).
//
//   read:  GET key -> hit? return it : load from RDS, SET key EX ttl, return it
//   write: UPDATE RDS, then DEL key (next read repopulates it)
//
// Plus three protections that keep latency flat under concurrent load:
//   - stampede lock: on a miss only one caller per key rebuilds, the rest wait briefly
//   - TTL jitter:    keys filled together do not all expire in the same second
//   - fail-open:     if the cache is unreachable, requests go straight to RDS
import Redis from 'ioredis';

const TTL_SECONDS = Number(process.env.CACHE_TTL_SECONDS ?? 300);
const TTL_JITTER_SECONDS = Number(process.env.CACHE_TTL_JITTER_SECONDS ?? 60);
const NEGATIVE_TTL_SECONDS = 30; // "not found" results, so bogus ids can't hammer RDS
const LOCK_TTL_MS = 3000;
const LOCK_WAIT_MS = 20;
const LOCK_MAX_WAITS = 10;

// Created once per execution environment and reused across invocations,
// so the TLS handshake is paid on cold start only.
export const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT ?? 6379),
  tls: {},
  connectTimeout: 2000,
  commandTimeout: 250,
  maxRetriesPerRequest: 1,
  enableAutoPipelining: true,
});
redis.on('error', (err) => console.warn('cache error:', err.message));

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const ttl = () => TTL_SECONDS + Math.floor(Math.random() * (TTL_JITTER_SECONDS + 1));

// Run a cache command; a failure is logged and reported, never thrown.
async function tryCache(fn) {
  try {
    return { ok: true, value: await fn() };
  } catch (err) {
    console.warn('cache unavailable, falling back to database:', err.message);
    return { ok: false };
  }
}

/**
 * Returns { data, cache } where cache is HIT | MISS | BYPASS.
 * `loader` fetches the value from the database and returns null when it doesn't exist.
 */
export async function cacheAside(key, loader) {
  const cached = await tryCache(() => redis.get(key));
  if (!cached.ok) return { data: await loader(), cache: 'BYPASS' };
  if (cached.value !== null) return { data: JSON.parse(cached.value), cache: 'HIT' };

  // Miss. Try to become the single rebuilder for this key.
  const lockKey = `lock:${key}`;
  const lock = await tryCache(() => redis.set(lockKey, '1', 'PX', LOCK_TTL_MS, 'NX'));
  const isRebuilder = !lock.ok || lock.value === 'OK';

  if (!isRebuilder) {
    // Someone else is already loading it; wait for their result instead of piling onto RDS.
    for (let i = 0; i < LOCK_MAX_WAITS; i++) {
      await sleep(LOCK_WAIT_MS);
      const again = await tryCache(() => redis.get(key));
      if (again.ok && again.value !== null) return { data: JSON.parse(again.value), cache: 'HIT' };
    }
    // Rebuilder is slow or died; load it ourselves rather than fail the request.
  }

  const data = await loader();
  await tryCache(() =>
    redis.set(key, JSON.stringify(data), 'EX', data === null ? NEGATIVE_TTL_SECONDS : ttl()),
  );
  if (isRebuilder && lock.ok) await tryCache(() => redis.del(lockKey));
  return { data, cache: 'MISS' };
}

export async function invalidate(...keys) {
  await tryCache(() => redis.del(...keys));
}

export async function cacheStats() {
  const info = await redis.info('stats');
  const field = (name) => Number(info.match(new RegExp(`^${name}:(\\d+)`, 'm'))?.[1] ?? 0);
  const hits = field('keyspace_hits');
  const misses = field('keyspace_misses');
  return {
    keyspace_hits: hits,
    keyspace_misses: misses,
    hit_ratio: hits + misses === 0 ? null : Number((hits / (hits + misses)).toFixed(4)),
    keys: await redis.dbsize(),
  };
}
