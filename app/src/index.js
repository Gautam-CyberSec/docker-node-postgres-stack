import { createPool, createRepository } from "./db.js";
import { createApp, startServer } from "./server.js";

const port = Number(process.env.PORT ?? 3000);

let pool;
try {
  pool = createPool();
} catch (err) {
  // Fail loudly at boot rather than serving 500s later. A container that cannot
  // be configured correctly should never reach a ready state.
  console.error(`configuration error: ${err.message}`);
  process.exit(1);
}

const app = createApp({ repository: createRepository(pool) });
startServer(app, { port, pool });
