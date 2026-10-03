FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.mjs ./

ENV HOST=0.0.0.0 \
    PORT=3000 \
    NODE_ENV=production

EXPOSE 3000

CMD ["node", "server.mjs"]
