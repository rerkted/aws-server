FROM node:20-alpine

# Patch OS packages
RUN apk upgrade --no-cache

WORKDIR /app

COPY package.json .
RUN npm install --omit=dev

COPY server.js .

# Run as non-root user
RUN addgroup -S rerktai && adduser -S rerktai -G rerktai
USER rerktai

EXPOSE 3001

CMD ["node", "server.js"]
