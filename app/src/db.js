import pg from "pg";

/**
 * Connection pool.
 *
 * Every value comes from the environment at runtime — nothing is baked into the
 * image, so the same artefact runs in dev, staging and production. See
 * .env.example for the full set.
 */
export function createPool(env = process.env) {
  const required = ["POSTGRES_HOST", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"];
  const missing = required.filter((k) => !env[k]);
  if (missing.length) {
    throw new Error(`missing required environment variables: ${missing.join(", ")}`);
  }

  return new pg.Pool({
    host: env.POSTGRES_HOST,
    port: Number(env.POSTGRES_PORT ?? 5432),
    user: env.POSTGRES_USER,
    password: env.POSTGRES_PASSWORD,
    database: env.POSTGRES_DB,

    // A container that cannot reach the database should fail its readiness probe
    // promptly rather than hanging until an orchestrator's own timeout fires.
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30000,
    max: Number(env.POSTGRES_POOL_MAX ?? 10),
  });
}

/**
 * Minimal data access. Kept behind an interface so the HTTP layer can be tested
 * with a stub instead of a live Postgres.
 */
export function createRepository(pool) {
  return {
    async ping() {
      await pool.query("SELECT 1");
    },

    async listItems(limit = 50) {
      const { rows } = await pool.query(
        "SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT $1",
        [limit],
      );
      return rows;
    },

    async createItem(name) {
      const { rows } = await pool.query(
        "INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at",
        [name],
      );
      return rows[0];
    },
  };
}
