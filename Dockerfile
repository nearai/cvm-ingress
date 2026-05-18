# Upstream nginx 1.29 on Debian Bookworm. Compiled with --with-http_v3_module
# (verify: docker run --rm nginx:1.29-bookworm nginx -V 2>&1 | grep http_v3_module).
# Pinned to the multi-platform index digest published 2025-09-29.
FROM nginx:1.29-bookworm@sha256:8adbdcb969e2676478ee2c7ad333956f0c8e0e4c5a7463f4611d7a2e7a7ff5dc

ARG SOURCE_DATE_EPOCH=0
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    DEBIAN_FRONTEND=noninteractive

# Bootstrap certificates so apt can reach the Debian snapshot over HTTPS.
# (ca-certificates is already present in the upstream nginx image, but we
# re-run to keep the bootstrap step idempotent and explicit.)
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache

# Install the remaining userland tooling from the pinned Debian snapshot.
# nginx itself is provided by the upstream image (from nginx.org's repo) and
# is intentionally NOT listed here — pinning it via Debian's archive would
# downgrade it to 1.22.x which lacks --with-http_v3_module.
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
    # --allow-downgrades is necessary because the upstream nginx image ships
    # newer curl/libcurl4 (from nginx.org's mirrored debs) than the pinned
    # Debian snapshot. Pinning to the snapshot keeps the rest of userland
    # reproducible at the cost of one downgrade.
    apt-get install -y --no-install-recommends --allow-downgrades \
        bash \
        ca-certificates \
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

# 8443/tcp: HTTP/1.1, HTTP/2 (TLS over TCP).
# 8443/udp: HTTP/3 (QUIC over UDP). Documentation-only — the actual host-level
# UDP path (cpu01/cpu02 L4 nginx + QEMU SLIRP hostfwd) is not wired up yet.
# See the PR description for the deployment blockers.
EXPOSE 8443/tcp 8443/udp

# Override the upstream nginx image's entrypoint/cmd. Upstream defaults to
# /docker-entrypoint.sh + ["nginx", "-g", "daemon off;"]; we run our own
# entrypoint which exec's nginx itself.
ENTRYPOINT ["/app/entrypoint.sh"]
CMD []
