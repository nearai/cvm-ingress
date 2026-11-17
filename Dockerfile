# PENDING PUBLICATION: locally assembled digest; anonymous pull is not verified.
FROM nearaidev/apt-bundle-cvm-ingress@sha256:5fb4259e59100090207fc914879aba8c3a75b6d72e48670c47a3dff1c6a21623 AS apt-bundle
FROM scratch AS apt-bundle-files
COPY --from=apt-bundle /apt-bundle /apt-bundle

# Upstream nginx 1.29 on Debian Bookworm. Compiled with --with-http_v3_module
# (verify: docker run --rm nginx:1.29-bookworm nginx -V 2>&1 | grep http_v3_module).
# Pinned to the multi-platform index digest published 2025-09-29.
FROM nginx:1.29-bookworm@sha256:8adbdcb969e2676478ee2c7ad333956f0c8e0e4c5a7463f4611d7a2e7a7ff5dc

ARG SOURCE_DATE_EPOCH=0
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    DEBIAN_FRONTEND=noninteractive

# Install userland tooling offline from the signed, pinned Debian snapshot.
# (ca-certificates is already present in the upstream nginx image at the
# version pinned below, so we do NOT run a bootstrap apt-get against live
# repos — that would drift whenever upstream republishes the package.)
# nginx itself is provided by the upstream image (from nginx.org's repo) and
# is intentionally NOT listed here — pinning it via Debian's archive would
# downgrade it to 1.22.x which lacks --with-http_v3_module.
# The helper is reviewed source; trust roots come from the pinned base image.
RUN --network=none \
    --mount=type=bind,from=apt-bundle-files,source=/apt-bundle,target=/opt/apt-bundle,ro \
    --mount=type=bind,source=build/apt-bundle/prepare-apt.sh,target=/run/prepare-apt.sh,ro \
    --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    bash /run/prepare-apt.sh --bundle /opt/apt-bundle \
        --snapshot 20250411T024939Z --config /tmp/apt-bundle.conf \
        --debian-keyring /usr/share/keyrings/debian-archive-keyring.gpg \
        --status /var/lib/dpkg/status --pins /tmp/pinned-packages.txt && \
    if [ -f /var/lib/apt/extended_states ]; then \
        cp /var/lib/apt/extended_states /tmp/apt-bundle.conf.d/state/extended_states; \
    fi && \
    export APT_CONFIG=/tmp/apt-bundle.conf && \
    apt-get update --error-on=any && \
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
    cp /tmp/apt-bundle.conf.d/state/extended_states /var/lib/apt/extended_states && \
    rm -rf /tmp/apt-bundle.conf /tmp/apt-bundle.conf.d \
        /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache

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
