FROM nginx:1.27-alpine

# Patch all OS packages
RUN apk upgrade --no-cache

# Remove default nginx content
RUN rm -rf /usr/share/nginx/html/*

# Copy portfolio website
COPY ./website/ /usr/share/nginx/html/

# Copy Rerkt.AI chat UI
RUN mkdir -p /usr/share/nginx/ai
COPY ./chat/index.html /usr/share/nginx/ai/

# Copy nginx configs
COPY nginx.conf /etc/nginx/nginx.conf
COPY nginx-ssl.conf /etc/nginx/nginx-ssl.conf

# Create certbot webroot directory
RUN mkdir -p /var/www/certbot

# Fix permissions
RUN chown -R nginx:nginx /usr/share/nginx/html /usr/share/nginx/ai && \
    chmod -R 755 /usr/share/nginx/html /usr/share/nginx/ai

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
