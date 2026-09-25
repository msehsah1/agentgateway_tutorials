# Agentgateway + Playwright MCP + self-hosted Firecrawl

A Docker Compose stack that puts [Agentgateway](https://agentgateway.dev/docs/standalone/latest/documentation/setup/install/docker/) in front of browser automation and web scraping tools, and exposes them to MCP clients as **one federated MCP endpoint**, with metrics, traces, and logs included.

Behind the gateway:

- **[Playwright MCP](https://www.npmjs.com/package/@playwright/mcp)**, the official server, for driving a real browser (navigate, click, fill forms, take snapshots)
- **[Firecrawl](https://docs.firecrawl.dev/contributing/self-host)**, self-hosted, for scraping, crawling, and extracting clean content from the web
- **[Firecrawl MCP](https://mcp.so/servers/firecrawl-mcp-server)**, the official server, pointed at the self-hosted Firecrawl API rather than the cloud service

MCP clients only ever talk to Agentgateway. Playwright MCP and Firecrawl MCP stay private on the Compose network, so the gateway is the single place to handle access, routing, and observability.

## Architecture

```text
                         ┌──────────────────────────── Compose network ────────────────────────────┐
                         │                                                                         │
MCP client ──────────────┼──▶ Agentgateway :4000/mcp ──┬──▶ playwright-mcp :8931/mcp                 │
(Claude, Cursor, VS Code)│         │                   │                                           │
                         │         │                   └──▶ firecrawl-mcp :3000/mcp ──▶ firecrawl-api :3002
Browser ─────────────────┼──▶ UI :4000/ui               │                                           │
                         │         │                                                               │
                         │         ├── metrics :15020 ──▶ Prometheus :9090                          │
                         │         └── OTLP ──▶ collector :4317 ──┬──▶ Jaeger :16686  (traces)      │
                         │                                         └──▶ Loki :3100 ──▶ Grafana :3000 (logs)
                         └─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Docker Engine with Compose v2 (`docker compose version`)
- These ports free on **localhost**: `3000`, `3002`, `3100`, `4000`, `9090`, `15020`, `16686`

To prepare a fresh host, run [`scripts/setup.sh`](scripts/setup.sh).

## Quick start

```sh
# 1. Create your environment file
cp .env.example .env
#    Optional but recommended: set POSTGRES_PASSWORD in .env to 32+ random characters
#    e.g.  openssl rand -base64 32
# 2. Build and start everything
docker compose up -d --build
# 3. Check that all services are running
docker compose ps
```

## Verify the stack

1. Open the MCP Tool Playground at http://localhost:4000/ui/mcp/playground.
2. Click **Initialize**.
3. You should see a **session id** and a **tools discovered** list containing both Playwright and Firecrawl tools.

To check Firecrawl directly, bypassing MCP:

```sh
curl -s -X POST http://localhost:3002/v1/scrape \
  -H 'Content-Type: application/json' \
  -d '{"url": "https://example.com", "formats": ["markdown"]}'
```

## Endpoints

| Service | URL | Notes |
| --- | --- | --- |
| **Federated MCP** | http://localhost:4000/mcp | The endpoint clients connect to. Serves Playwright + Firecrawl tools |
| Agentgateway UI | http://localhost:4000/ui | Dashboard and MCP Tool Playground |
| Agentgateway metrics | http://localhost:15020/metrics | Prometheus format, e.g. `mcp_requests_total` |
| Prometheus | http://localhost:9090 | Scrapes `agentgateway:15020` every 15s |
| Jaeger | http://localhost:16686 | MCP request traces (OTLP via the collector on `:4317`) |
| Grafana | http://localhost:3000 | Loki Explore plus the **Agentgateway MCP logs** dashboard |
| Loki | http://localhost:3100 | OTLP log store (`/ready`, LogQL API) |
| Firecrawl API | http://localhost:3002 | Published for direct smoke tests |
| Playwright MCP | `http://playwright-mcp:8931/mcp` | Internal only, not published to the host |
| Firecrawl MCP | `http://firecrawl-mcp:3000/mcp` | Internal only, not published to the host |

> Grafana's host port `3000` and Firecrawl MCP's container port `3000` don't collide: Firecrawl MCP is never published to the host.

## Connect an MCP client

Point any client that supports the **Streamable HTTP** transport at:

```text
http://localhost:4000/mcp
```

Tools from both backends appear under a single server, namespaced by the backend they come from.

### VS Code (GitHub Copilot)

`.vscode/mcp.json`:

```json
{
  "servers": {
    "agentgateway": {
      "type": "http",
      "url": "http://localhost:4000/mcp"
    }
  }
}
```

## Observability

Every MCP call through the gateway is recorded as metrics, traces, and logs.

**Metrics.** In Prometheus (http://localhost:9090), try:

```promql
sum by (method) (rate(mcp_requests_total[5m]))
```

**Traces.** In Jaeger (http://localhost:16686), select the Agentgateway service to follow a single tool call end to end.

**Logs.** In Grafana (http://localhost:3000), open the **Agentgateway MCP logs** dashboard, or use Explore with the Loki data source. From the CLI:


## Operations

```sh
# Follow logs for the MCP path
docker compose logs -f agentgateway playwright-mcp firecrawl-mcp

# Restart one service
docker compose restart agentgateway

# Rebuild after changing config or images
docker compose up -d --build

# Stop the stack (keeps volumes and data)
docker compose down

# Stop and wipe all data volumes (Postgres, Loki, Prometheus, ...) — destructive
docker compose down -v
```

## Troubleshooting

**The Playground shows no tools, or Initialize fails.**
Check that the backends started and are listening:

```sh
docker compose ps
docker compose logs --tail=30 agentgateway playwright-mcp firecrawl-mcp
```

If a backend is restarting or unhealthy, do a clean restart:

```sh
docker compose down
docker compose up -d --build
docker compose ps
```

Then reopen http://localhost:4000/ui/mcp/playground and click **Initialize** again.

```sh
docker compose logs --since 15m agentgateway | grep 'protocol=mcp'
```