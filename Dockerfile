FROM python:3.12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nginx \
        openssl \
        curl \
        jq \
        gettext-base && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    certbot \
    certbot-dns-cloudflare \
    awscli

RUN mkdir -p /certs /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt /run/nginx && \
    chown -R www-data:www-data /certs /run/nginx

# Remove default nginx site
RUN rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

COPY entrypoint.sh /app/entrypoint.sh
COPY lib/ /app/lib/
COPY nginx/ /app/nginx/

RUN chmod +x /app/entrypoint.sh /app/lib/*.sh

EXPOSE 8443

ENTRYPOINT ["/app/entrypoint.sh"]
