# Agentgateway + Keycloak + Postgres MCP

A Docker Compose stack that puts [Agentgateway](https://agentgateway.dev/docs/standalone/latest/documentation/setup/install/docker/) in front of a Postgres MCP server and protects it with [Keycloak](https://www.keycloak.org/server/containers). MCP clients must log in before they can call a tool, and only users with the right role get through. Metrics, traces, and logs are included.

Behind the gateway:

- **[Postgres MCP](mcp/postgres-mcp)**, a Streamable HTTP server with four read-only tools
- **PostgreSQL**, with a demo store database of five tables filled with test rows
- **Keycloak**, the identity provider that logs users in and issues tokens

MCP clients only ever talk to Agentgateway. Postgres and Postgres MCP stay private on the Compose network, so the gateway is the single place to check identity, enforce roles, and record every call.

## Architecture

```text
                      ┌────────────────────── Compose network ──────────────────────
                      │
MCP client ───────────┼──▶ Agentgateway :4000/mcp ──▶ postgres-mcp :3000/mcp ──▶ postgres :5432
(VS Code, Copilot)    │         │   validates JWT,
                      │         │   checks role
Browser (login) ──────┼──▶ Keycloak :8080 ◀── JWKS ──┘
                      │         
                      │    Agentgateway ├── metrics :15020 ──▶ Prometheus :9090
                      │                 └── OTLP ──▶ collector :4317 ──┬──▶ Jaeger :16686  (traces)
                      │                                                └──▶ Loki :3100 ──▶ Grafana :3000 (logs)
                      └──────────────────────────────────────────────────────────────
```


## Setups

To prepare a fresh host, run [`scripts/setup.sh`](scripts/setup.sh).

## Endpoints

| Service | URL | Notes |
| --- | --- | --- |
| **MCP endpoint** | http://localhost:4000/mcp | The endpoint clients connect to. Requires a Keycloak token |
| Agentgateway UI | http://localhost:4000/ui | Dashboard and MCP Tool Playground |
| Keycloak | http://localhost:8080 | Admin console (`admin` / `admin`), realm `mcp` |
| Agentgateway metrics | http://localhost:15020/metrics | Prometheus format, e.g. `mcp_requests_total` |
| Prometheus | http://localhost:9090 | Scrapes `agentgateway:15020` every 15s |
| Jaeger | http://localhost:16686 | MCP request traces (OTLP via the collector on `:4317`) |
| Grafana | http://localhost:3000 | Loki Explore plus the **Agentgateway MCP logs** dashboard |
| Loki | http://localhost:3100 | OTLP log store (`/ready`, LogQL API) |
| Postgres | `127.0.0.1:5432` | Demo database `store` (credentials in `.env`) |
| Postgres MCP | `http://postgres-mcp:3000/mcp` | Internal only, not published to the host |

> Grafana's host port `3000` and Postgres MCP's container port `3000` don't collide: Postgres MCP is never published to the host.

## Connect an MCP client

Point any client that supports the **Streamable HTTP** transport and MCP authorization at:

```text
http://localhost:4000/mcp
```

The client opens a browser to Keycloak. Sign in as `mcpuser` / `mcppassword`.
