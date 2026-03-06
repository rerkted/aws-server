# ─── bedrock/Dockerfile ───────────────────────────────────────
# Rerkt.AI Bedrock — Node.js proxy for AWS Bedrock

FROM node:20-alpine

# Patch OS packages
RUN apk update && apk upgrade --no-cache

WORKDIR /app

COPY package*.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY server.js ./

# Run as non-root user
RUN addgroup -S rerktai && adduser -S rerktai -G rerktai
USER rerktai

EXPOSE 3002

CMD ["node", "server.js"]
