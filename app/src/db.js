// RDS PostgreSQL access. The pool is created lazily: an execution environment that
// only ever serves cache hits never opens a database connection at all.
import { readFileSync } from 'node:fs';
import pg from 'pg';

let pool;

function getPool() {
  if (!pool) {
    pool = new pg.Pool({
      host: process.env.DB_HOST,
      port: Number(process.env.DB_PORT ?? 5432),
      database: process.env.DB_NAME,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      // A Lambda environment handles one request at a time, so one connection is enough.
      // Total DB connections are therefore capped by the function's reserved concurrency.
      max: 1,
      idleTimeoutMillis: 60_000,
      connectionTimeoutMillis: 3000,
      // RDS enforces TLS; verify the server against the AWS RDS CA bundle shipped in the package.
      ssl: { ca: readFileSync(new URL('../rds-ca.pem', import.meta.url)) },
    });
    pool.on('error', (err) => console.warn('db pool error:', err.message));
  }
  return pool;
}

export async function getProduct(id) {
  const { rows } = await getPool().query(
    `SELECT p.id, p.name, p.category, p.price::float AS price, p.stock, p.description, p.updated_at,
            r.review_count, r.avg_rating
       FROM products p
       CROSS JOIN LATERAL (
         SELECT count(*)::int AS review_count, round(avg(rating), 2)::float AS avg_rating
           FROM reviews WHERE product_id = p.id
       ) r
      WHERE p.id = $1`,
    [id],
  );
  return rows[0] ?? null;
}

export async function getTopRated(category) {
  const { rows } = await getPool().query(
    `SELECT p.id, p.name, p.price::float AS price,
            count(*)::int AS review_count, round(avg(r.rating), 2)::float AS avg_rating
       FROM products p
       JOIN reviews r ON r.product_id = p.id
      WHERE p.category = $1
      GROUP BY p.id
      ORDER BY avg_rating DESC, review_count DESC
      LIMIT 10`,
    [category],
  );
  return rows.length ? { category, products: rows } : null;
}

export async function updateProduct(id, { price, stock }) {
  const { rows } = await getPool().query(
    `UPDATE products
        SET price = COALESCE($2, price), stock = COALESCE($3, stock), updated_at = now()
      WHERE id = $1
      RETURNING id, category`,
    [id, price ?? null, stock ?? null],
  );
  return rows[0] ?? null;
}

export const CATEGORIES = ['electronics', 'books', 'home', 'toys', 'sports', 'beauty', 'garden', 'grocery'];

// Idempotent schema + synthetic data. Invoked once by Terraform (aws_lambda_invocation).
export async function seed({ products, reviews }) {
  const client = await getPool().connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS products (
        id          int PRIMARY KEY,
        name        text NOT NULL,
        category    text NOT NULL,
        price       numeric(10, 2) NOT NULL,
        stock       int NOT NULL,
        description text,
        updated_at  timestamptz NOT NULL DEFAULT now()
      );
      CREATE TABLE IF NOT EXISTS reviews (
        id         bigserial PRIMARY KEY,
        product_id int NOT NULL REFERENCES products (id),
        rating     smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
        created_at timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX IF NOT EXISTS reviews_product_id_idx ON reviews (product_id);
      CREATE INDEX IF NOT EXISTS products_category_idx ON products (category);
    `);
    await client.query(
      `INSERT INTO products (id, name, category, price, stock, description)
       SELECT g, 'Product ' || g, ($2::text[])[1 + g % array_length($2::text[], 1)],
              round((5 + random() * 495)::numeric, 2), (random() * 500)::int,
              'Synthetic catalog item #' || g
         FROM generate_series(1, $1::int) g
       ON CONFLICT (id) DO NOTHING`,
      [products, CATEGORIES],
    );
    const { rows: [{ n }] } = await client.query('SELECT count(*)::int AS n FROM reviews');
    if (n === 0) {
      await client.query(
        `INSERT INTO reviews (product_id, rating)
         SELECT 1 + floor(random() * $1::int)::int, 1 + floor(random() * 5)::int
           FROM generate_series(1, $2::int)`,
        [products, reviews],
      );
    }
    await client.query('ANALYZE products; ANALYZE reviews;');
    const { rows: [counts] } = await client.query(
      `SELECT (SELECT count(*) FROM products)::int AS products, (SELECT count(*) FROM reviews)::int AS reviews,
              current_setting('max_connections')::int AS max_connections`,
    );
    return counts;
  } finally {
    client.release();
  }
}
