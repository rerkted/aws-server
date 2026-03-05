# ─── STAGE 1: Build ───────────────────────────────────────────
# Golden image: lightweight, secure, and reproducible
FROM nginx:1.25-alpine AS final

# Remove default nginx content
RUN rm -rf /usr/share/nginx/html/*

# Copy website files
COPY ./website/ /usr/share/nginx/html/

# Copy custom nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Security hardening
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    chmod -R 755 /usr/share/nginx/html && \
    # Remove unnecessary tools
    rm -f /bin/sh /usr/bin/wget /usr/bin/curl 2>/dev/null || true

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost/health || exit 1

EXPOSE 80

LABEL maintainer="your@email.com" \
      version="1.0" \
      description="Portfolio website - golden image"

CMD ["nginx", "-g", "daemon off;"]