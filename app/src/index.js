// Lambda entry point. Receives HTTP requests from the ALB (and a one-off
// { action: "seed" } event from Terraform) and routes them.
//
//   GET  /health                        liveness, touches nothing
//   GET  /products/{id}                 product + review stats   (cache-aside)
//   GET  /products/top?category=books   top 10 rated in category (cache-aside)
//   PUT  /products/{id}  {price,stock}  update in RDS, invalidate cached keys
//   GET  /db/products/{id}              same as /products/{id} but never cached (benchmark baseline)
//   GET  /stats                         cache hit ratio from ElastiCache
import { STATUS_CODES } from 'node:http';
import { cacheAside, cacheStats, invalidate } from './cache.js';
import { CATEGORIES, getProduct, getTopRated, seed, updateProduct } from './db.js';

const productKey = (id) => `product:${id}`;
const topKey = (category) => `top:${category}`;

function respond(statusCode, body, headers = {}) {
  return {
    statusCode,
    statusDescription: `${statusCode} ${STATUS_CODES[statusCode]}`, // ALB requires e.g. "200 OK"
    isBase64Encoded: false,
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body),
  };
}

function parseId(raw) {
  const id = Number(raw);
  return Number.isInteger(id) && id > 0 ? id : null;
}

function parseBody(event) {
  if (!event.body) return {};
  const text = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body;
  return JSON.parse(text);
}

async function route(method, path, event) {
  if (method === 'GET' && path === '/health') return respond(200, { status: 'ok' });

  if (method === 'GET' && path === '/stats') return respond(200, await cacheStats());

  if (method === 'GET' && path === '/products/top') {
    const category = decodeURIComponent(event.queryStringParameters?.category ?? '');
    if (!CATEGORIES.includes(category)) {
      return respond(400, { error: `category must be one of: ${CATEGORIES.join(', ')}` });
    }
    const { data, cache } = await cacheAside(topKey(category), () => getTopRated(category));
    return respond(data ? 200 : 404, data ?? { error: 'not found' }, { 'X-Cache': cache });
  }

  let match = path.match(/^\/products\/([^/]+)$/);
  if (match) {
    const id = parseId(match[1]);
    if (!id) return respond(400, { error: 'id must be a positive integer' });

    if (method === 'GET') {
      const { data, cache } = await cacheAside(productKey(id), () => getProduct(id));
      return respond(data ? 200 : 404, data ?? { error: 'not found' }, { 'X-Cache': cache });
    }

    if (method === 'PUT') {
      let body;
      try {
        body = parseBody(event);
      } catch {
        return respond(400, { error: 'body must be JSON' });
      }
      const price = body.price === undefined ? undefined : Number(body.price);
      const stock = body.stock === undefined ? undefined : Number(body.stock);
      if ((price !== undefined && !(price >= 0)) || (stock !== undefined && !Number.isInteger(stock))) {
        return respond(400, { error: 'price must be >= 0 and stock an integer' });
      }
      const updated = await updateProduct(id, { price, stock });
      if (!updated) return respond(404, { error: 'not found' });
      // Write to the source of truth first, then drop every cached view of that row.
      await invalidate(productKey(id), topKey(updated.category));
      return respond(200, { id, updated: true });
    }
  }

  match = path.match(/^\/db\/products\/([^/]+)$/);
  if (match && method === 'GET') {
    const id = parseId(match[1]);
    if (!id) return respond(400, { error: 'id must be a positive integer' });
    const data = await getProduct(id);
    return respond(data ? 200 : 404, data ?? { error: 'not found' }, { 'X-Cache': 'BYPASS' });
  }

  return respond(404, { error: 'route not found' });
}

export async function handler(event) {
  if (event.action === 'seed') {
    const counts = await seed({ products: event.products ?? 10000, reviews: event.reviews ?? 300000 });
    return { seeded: true, ...counts };
  }

  try {
    return await route(event.httpMethod, event.path, event);
  } catch (err) {
    console.error('request failed:', err);
    return respond(500, { error: 'internal error' });
  }
}
