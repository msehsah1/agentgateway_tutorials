import { randomUUID } from "node:crypto";
import express from "express";
import pg from "pg";
import { z } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";

const HOST = process.env.HOST ?? "0.0.0.0";
const PORT = Number(process.env.PORT ?? 3000);
const DATABASE_URL = process.env.DATABASE_URL;
const PGHOST = process.env.PGHOST ?? "postgres";
const PGPORT = Number(process.env.PGPORT ?? 5432);
const PGUSER = process.env.POSTGRES_USER ?? process.env.PGUSER ?? "postgres";
const PGPASSWORD = process.env.POSTGRES_PASSWORD ?? process.env.PGPASSWORD ?? "";
const PGDATABASE = process.env.POSTGRES_DB ?? process.env.PGDATABASE ?? "store";

const pool = new pg.Pool(
  DATABASE_URL
    ? { connectionString: DATABASE_URL, max: 8 }
    : {
        host: PGHOST,
        port: PGPORT,
        user: PGUSER,
        password: PGPASSWORD,
        database: PGDATABASE,
        max: 8,
      },
);

function log(message) {
  console.log(`postgres-mcp: ${message}`);
}

function stripSqlComments(sql) {
  return sql.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ");
}

function assertReadOnlySql(sql) {
  const stripped = stripSqlComments(sql).trim();
  if (!stripped) {
    throw new Error("SQL is empty");
  }
  const withoutTrailing = stripped.replace(/;+\s*$/g, "");
  if (withoutTrailing.includes(";")) {
    throw new Error("Only a single SQL statement is allowed");
  }
  if (!/^(SELECT|WITH|SHOW|EXPLAIN|TABLE)\b/i.test(withoutTrailing)) {
    throw new Error("Only read-only queries (SELECT, WITH, SHOW, EXPLAIN, TABLE) are allowed");
  }
  return withoutTrailing;
}

function asText(value) {
  return {
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }],
  };
}

function asError(error) {
  const message = error instanceof Error ? error.message : String(error);
  return {
    content: [{ type: "text", text: message }],
    isError: true,
  };
}

async function query(sql, params = []) {
  const client = await pool.connect();
  try {
    await client.query("SET default_transaction_read_only = on");
    return await client.query(sql, params);
  } finally {
    client.release();
  }
}

function createServer() {
  const server = new McpServer({
    name: "postgres-mcp",
    version: "1.0.0",
  });

  server.tool(
    "postgres_list_tables",
    "List public tables in the demo store database.",
    {},
    async () => {
      try {
        const { rows } = await query(`
          SELECT table_name
          FROM information_schema.tables
          WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
          ORDER BY table_name
        `);
        return asText(rows);
      } catch (error) {
        return asError(error);
      }
    },
  );

  server.tool(
    "postgres_describe_table",
    "Describe columns and types for a public table.",
    { table: z.string().min(1).describe("Public table name, for example orders") },
    async ({ table }) => {
      try {
        const { rows } = await query(
          `
          SELECT column_name, data_type, is_nullable, column_default
          FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = $1
          ORDER BY ordinal_position
        `,
          [table],
        );
        if (rows.length === 0) {
          return asError(new Error(`Table not found: ${table}`));
        }
        return asText(rows);
      } catch (error) {
        return asError(error);
      }
    },
  );

  server.tool(
    "postgres_table_counts",
    "Return row counts for every public table in the demo store.",
    {},
    async () => {
      try {
        const { rows: tables } = await query(`
          SELECT table_name
          FROM information_schema.tables
          WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
          ORDER BY table_name
        `);
        const counts = [];
        for (const { table_name } of tables) {
          if (!/^[a-z_][a-z0-9_]*$/.test(table_name)) {
            continue;
          }
          const { rows } = await query(`SELECT count(*)::int AS row_count FROM ${table_name}`);
          counts.push({ table_name, row_count: rows[0].row_count });
        }
        return asText(counts);
      } catch (error) {
        return asError(error);
      }
    },
  );

  server.tool(
    "postgres_query",
    "Run a single read-only SQL statement against the demo store.",
    { sql: z.string().min(1).describe("A single SELECT / WITH / SHOW / EXPLAIN / TABLE statement") },
    async ({ sql }) => {
      try {
        const safeSql = assertReadOnlySql(sql);
        const result = await query(safeSql);
        return asText({
          rowCount: result.rowCount,
          rows: result.rows,
        });
      } catch (error) {
        return asError(error);
      }
    },
  );

  return server;
}

const transports = new Map();

function createTransport() {
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    onsessioninitialized: (sessionId) => {
      transports.set(sessionId, transport);
    },
  });
  transport.onclose = () => {
    if (transport.sessionId) {
      transports.delete(transport.sessionId);
    }
  };
  return transport;
}

const app = express();
app.use(express.json({ limit: "1mb" }));

app.get("/health", async (_req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ok" });
  } catch (error) {
    res.status(503).json({
      status: "error",
      error: error instanceof Error ? error.message : String(error),
    });
  }
});

app.post("/mcp", async (req, res) => {
  const sessionId = req.headers["mcp-session-id"];
  try {
    let transport;
    if (typeof sessionId === "string" && transports.has(sessionId)) {
      transport = transports.get(sessionId);
    } else if (!sessionId && isInitializeRequest(req.body)) {
      transport = createTransport();
      const server = createServer();
      await server.connect(transport);
    } else {
      res.status(400).json({
        jsonrpc: "2.0",
        error: { code: -32000, message: "Bad Request: no valid session ID" },
        id: null,
      });
      return;
    }
    await transport.handleRequest(req, res, req.body);
  } catch (error) {
    log(`MCP POST failed: ${error instanceof Error ? error.message : error}`);
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: "2.0",
        error: { code: -32603, message: "Internal server error" },
        id: null,
      });
    }
  }
});

async function handleSessionRequest(req, res) {
  const sessionId = req.headers["mcp-session-id"];
  if (typeof sessionId !== "string" || !transports.has(sessionId)) {
    res.status(400).send("Invalid or missing session ID");
    return;
  }
  await transports.get(sessionId).handleRequest(req, res);
}

app.get("/mcp", handleSessionRequest);
app.delete("/mcp", handleSessionRequest);

async function waitForDatabase() {
  for (let attempt = 1; attempt <= 60; attempt += 1) {
    try {
      await pool.query("SELECT 1");
      return;
    } catch (error) {
      log(`database not ready (${attempt}/60): ${error instanceof Error ? error.message : error}`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }
  throw new Error(`Postgres at ${PGHOST}:${PGPORT}/${PGDATABASE} never accepted connections`);
}

await waitForDatabase();
app.listen(PORT, HOST, () => {
  log(`listening on http://${HOST}:${PORT}/mcp (${PGHOST}:${PGPORT}/${PGDATABASE})`);
});
