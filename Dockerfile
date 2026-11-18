# Upstream nginx 1.30.7 (stable) on Debian Trixie. Compiled with --with-http_v3_module
# (verify: docker run --rm nginx:1.30.7-trixie nginx -V 2>&1 | grep http_v3_module).
# Pinned to the linux/amd64 image manifest, the only platform build-image.sh builds.
FROM nginx:1.30.7-trixie@sha256:af61f605a001c7794200cae30093d8ee0da5183318df15fdfff3597ef37a7486

ARG SOURCE_DATE_EPOCH=0
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    DEBIAN_FRONTEND=noninteractive

# Install userland tooling from the pinned Debian snapshot.
# (ca-certificates is already present in the upstream nginx image at the
# version pinned below, so we do NOT run a bootstrap apt-get against live
# repos — that would drift whenever upstream republishes the package.)
# nginx itself is provided by the upstream image (from nginx.org's repo) and
# is intentionally NOT listed here — pinning it via Debian's archive would
# replace it with Debian's older nginx build.
# Snapshot CDN 503/504 bursts can outlast APT's default three retries. Allow
# five retries, keep a 30s connection/data inactivity timeout, and fail if
# any index is unavailable rather than proceeding with incomplete metadata.
RUN --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261117T000000Z trixie main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20261117T000000Z trixie-security main' >> /etc/apt/sources.list && \
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
    apt-get -o Acquire::Retries=5 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        update --error-on=any && \
    apt-get -o Acquire::Retries=5 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        install -y --no-install-recommends \
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
