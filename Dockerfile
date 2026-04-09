FROM debian:bookworm-slim@sha256:78d2f66e0fec9e5a39fb2c72ea5e052b548df75602b5215ed01a17171529f706

ARG SOURCE_DATE_EPOCH=0
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    DEBIAN_FRONTEND=noninteractive

# Bootstrap certificates so apt can reach the Debian snapshot over HTTPS.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache

RUN --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250411T024939Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250411T024939Z bookworm-security main' >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    rm -rf /etc/apt/sources.list.d/* && \
    mkdir -p /etc/apt/preferences.d && \
    while IFS= read -r line; do \
        pkg=$(echo "$line" | cut -d= -f1); \
        ver=$(echo "$line" | cut -d= -f2-); \
        if [ -n "$pkg" ] && [ -n "$ver" ] && [ "$pkg" != "$ver" ]; then \
            printf "Package: %s\nPin: version %s\nPin-Priority: 1001\n\n" "$pkg" "$ver" >> /etc/apt/preferences.d/pinned-packages; \
        fi; \
    done < /tmp/pinned-packages.txt && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        nginx \
        openssl \
        curl \
        jq \
        gettext-base \
        certbot \
        python3-certbot-dns-cloudflare \
        awscli && \
    rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache

RUN mkdir -p /certs /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt /var/log/nginx /run/nginx && \
    chown -R www-data:www-data /certs /run/nginx

# Remove default nginx site and install custom nginx.conf with stdout/stderr logging.
RUN rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

COPY --chmod=755 entrypoint.sh /app/entrypoint.sh
COPY --chmod=755 lib/ /app/lib/
COPY --chmod=644 nginx/ /app/nginx/
COPY --chmod=644 nginx/nginx.conf /etc/nginx/nginx.conf

RUN rm -rf \
    /var/log/dpkg.log \
    /var/log/apt/*.log \
    /etc/machine-id \
    /var/lib/dbus/machine-id \
    /tmp/* \
    /var/tmp/* && \
    mkdir -p /var/lib/dbus /var/log/apt /var/log/letsencrypt /var/log/nginx && \
    touch /etc/machine-id /var/lib/dbus/machine-id

EXPOSE 8443

ENTRYPOINT ["/app/entrypoint.sh"]
