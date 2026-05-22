FROM oven/bun:1.3.13-slim

WORKDIR /app
ENV NODE_ENV=production

COPY services/matrixbot/ ./

EXPOSE 3002
ENV PORT=3002
CMD ["bun", "src/index.ts"]
