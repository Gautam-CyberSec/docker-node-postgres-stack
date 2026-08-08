import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../src/server.js";
import { createPool } from "../src/db.js";

// A stub repository lets every path be exercised — including the database being
// unreachable — with no Postgres running. The container suite covers the real
// integration; these cover the logic.
function stubRepository(overrides = {}) {
  return {
    ping: async () => {},
    listItems: async () => [{ id: 1, name: "example", created_at: "2026-01-01T00:00:00Z" }],
    createItem: async (name) => ({ id: 2, name, created_at: "2026-01-01T00:00:00Z" }),
    ...overrides,
  };
}

const silent = { log() {}, error() {} };

async function request(app, method, path, body) {
  const server = app.listen(0);
  try {
    const { port } = server.address();
    const res = await fetch(`http://127.0.0.1:${port}${path}`, {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : null };
  } finally {
    server.close();
  }
}

describe("liveness and readiness", () => {
  test("healthz reports ok without touching the database", async () => {
    let touched = false;
    const app = createApp({
      repository: stubRepository({
        ping: async () => {
          touched = true;
        },
      }),
      logger: silent,
    });

    const res = await request(app, "GET", "/healthz");
    assert.equal(res.status, 200);
    assert.equal(res.body.status, "ok");
    // The important half of the assertion: a database outage must not make the
    // orchestrator restart healthy app containers.
    assert.equal(touched, false, "liveness must not depend on the database");
  });

  test("readyz reports ready when the database answers", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "GET", "/readyz");
    assert.equal(res.status, 200);
    assert.equal(res.body.status, "ready");
  });

  test("readyz returns 503 when the database is unreachable", async () => {
    const app = createApp({
      repository: stubRepository({
        ping: async () => {
          throw new Error("ECONNREFUSED");
        },
      }),
      logger: silent,
    });
    const res = await request(app, "GET", "/readyz");
    assert.equal(res.status, 503);
    assert.equal(res.body.status, "not ready");
  });
});

describe("items API", () => {
  test("lists items", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "GET", "/api/items");
    assert.equal(res.status, 200);
    assert.equal(res.body.items.length, 1);
  });

  test("creates an item", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "POST", "/api/items", { name: "widget" });
    assert.equal(res.status, 201);
    assert.equal(res.body.name, "widget");
  });

  test("trims whitespace from the name", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "POST", "/api/items", { name: "  spaced  " });
    assert.equal(res.body.name, "spaced");
  });

  test("rejects a missing name", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "POST", "/api/items", {});
    assert.equal(res.status, 400);
  });

  test("rejects a whitespace-only name", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "POST", "/api/items", { name: "   " });
    assert.equal(res.status, 400);
  });

  test("rejects an over-long name", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "POST", "/api/items", { name: "x".repeat(201) });
    assert.equal(res.status, 400);
  });

  test("rejects a non-string name", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "POST", "/api/items", { name: 42 });
    assert.equal(res.status, 400);
  });
});

describe("error handling", () => {
  test("unknown routes return 404", async () => {
    const app = createApp({ repository: stubRepository(), logger: silent });
    const res = await request(app, "GET", "/nope");
    assert.equal(res.status, 404);
  });

  test("a repository failure returns 500 without leaking the stack", async () => {
    const app = createApp({
      repository: stubRepository({
        listItems: async () => {
          throw new Error("relation \"items\" does not exist");
        },
      }),
      logger: silent,
    });
    const res = await request(app, "GET", "/api/items");
    assert.equal(res.status, 500);
    assert.equal(res.body.error, "internal server error");
    // The database's own error text must not reach the client.
    assert.equal(JSON.stringify(res.body).includes("items"), false);
  });
});

describe("configuration", () => {
  test("createPool rejects an incomplete environment", () => {
    assert.throws(
      () => createPool({ POSTGRES_HOST: "db" }),
      /missing required environment variables: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB/,
    );
  });

  test("createPool accepts a complete environment", () => {
    const pool = createPool({
      POSTGRES_HOST: "db",
      POSTGRES_USER: "app",
      POSTGRES_PASSWORD: "secret",
      POSTGRES_DB: "app",
    });
    assert.ok(pool);
    pool.end();
  });
});
