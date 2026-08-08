import express from "express";

/**
 * Build the app from injected dependencies.
 *
 * The repository is a parameter rather than a module-level import so the tests
 * can drive every path — including the database being unreachable — without a
 * live Postgres. That is what lets the unit suite run anywhere.
 */
export function createApp({ repository, logger = console }) {
  const app = express();
  app.use(express.json({ limit: "64kb" }));
  app.disable("x-powered-by");

  /**
   * Liveness: is the process itself healthy?
   *
   * Deliberately does NOT touch the database. If liveness depended on Postgres,
   * a brief database outage would make the orchestrator kill and restart every
   * app container — turning a recoverable blip into a restart storm.
   */
  app.get("/healthz", (_req, res) => {
    res.json({ status: "ok", uptime: Math.round(process.uptime()) });
  });

  /**
   * Readiness: should this instance receive traffic?
   *
   * This one does check the database, and returns 503 when it cannot. Compose
   * and Kubernetes both use it to hold traffic back until dependencies are
   * actually usable.
   */
  app.get("/readyz", async (_req, res) => {
    try {
      await repository.ping();
      res.json({ status: "ready" });
    } catch (err) {
      logger.error(`readiness check failed: ${err.message}`);
      res.status(503).json({ status: "not ready", reason: "database unreachable" });
    }
  });

  app.get("/api/items", async (_req, res, next) => {
    try {
      res.json({ items: await repository.listItems() });
    } catch (err) {
      next(err);
    }
  });

  app.post("/api/items", async (req, res, next) => {
    const name = typeof req.body?.name === "string" ? req.body.name.trim() : "";
    if (!name) {
      return res.status(400).json({ error: "name is required and must be a non-empty string" });
    }
    if (name.length > 200) {
      return res.status(400).json({ error: "name must be 200 characters or fewer" });
    }
    try {
      res.status(201).json(await repository.createItem(name));
    } catch (err) {
      next(err);
    }
  });

  app.use((_req, res) => res.status(404).json({ error: "not found" }));

  // Error details are logged, never returned: a stack trace in an HTTP response
  // tells an attacker about the stack, the paths and the library versions.
  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    logger.error(`unhandled error: ${err.stack ?? err.message}`);
    res.status(500).json({ error: "internal server error" });
  });

  return app;
}

/**
 * Start listening and wire up graceful shutdown.
 *
 * SIGTERM is what `docker stop` and Kubernetes send. Without handling it the
 * runtime waits out its full grace period and then SIGKILLs, which shows up as
 * a ten-second pause on every deploy and as dropped in-flight requests.
 */
export function startServer(app, { port, pool, logger = console }) {
  const server = app.listen(port, () => logger.log(`listening on :${port}`));

  const shutdown = async (signal) => {
    logger.log(`${signal} received, closing`);
    server.close(async () => {
      try {
        await pool?.end();
      } catch (err) {
        logger.error(`error closing the pool: ${err.message}`);
      }
      process.exit(0);
    });

    // Do not hang forever on a connection that will not drain.
    setTimeout(() => {
      logger.error("shutdown timed out, exiting");
      process.exit(1);
    }, 10000).unref();
  };

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));

  return server;
}
