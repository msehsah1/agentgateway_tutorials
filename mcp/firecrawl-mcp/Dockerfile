FROM node:22-alpine

# Official Firecrawl MCP server. Streamable HTTP is required so Agentgateway
# can proxy it. Pin matches https://docs.firecrawl.dev/mcp-server/local
RUN npm install -g firecrawl-mcp@3.23.7

ENV HTTP_STREAMABLE_SERVER=true \
    HOST=0.0.0.0 \
    PORT=3000 \
    NODE_ENV=production

EXPOSE 3000

CMD ["firecrawl-mcp"]
