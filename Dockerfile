# =============================================================================
# Firecracker Base Image - Single Layer Debian
# =============================================================================
# Uses multi-stage build with FROM scratch to produce exactly one layer.
#
# Stage 1 (builder): Install everything on top of debian:bookworm-slim
# Stage 2 (final):   COPY the entire filesystem into a scratch image -> 1 layer
# =============================================================================

FROM debian:bookworm-slim AS builder

RUN set -eux; \
    \
    export DEBIAN_FRONTEND=noninteractive; \
    \
    # -- Core packages --------------------------------------------------------
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        sudo \
        openssh-client \
        # Firecracker / Docker requirements
        docker.io \
        docker-compose \
        iptables \
        # Dev tools
        tmux \
        jq \
        unzip \
        procps \
        # Node.js (for Playwright)
        nodejs \
        npm \
    ; \
    \
    # -- iptables: switch to legacy backend -----------------------------------
    # Firecracker kernels do not support nftables
    if [ -x /usr/sbin/iptables-legacy ]; then \
        update-alternatives --set iptables  /usr/sbin/iptables-legacy; \
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true; \
    fi; \
    \
    # -- systemd: enable docker to start on boot ------------------------------
    mkdir -p /etc/systemd/system/multi-user.target.wants; \
    ln -sf /lib/systemd/system/docker.service \
        /etc/systemd/system/multi-user.target.wants/docker.service; \
    \
    \
    # -- Create default user with docker group access -------------------------
    useradd -m -s /bin/bash -G docker,sudo user; \
    echo 'user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/user; \
    \
    # -- npm global prefix (non-root installs) --------------------------------
    mkdir -p /home/user/.npm-global; \
    \
    # -- Playwright (global install + Chromium) -------------------------------
    npm install -g playwright; \
    npx playwright install-deps chromium; \
    npx playwright install chromium; \
    \
    # -- SSH known hosts for common forges ------------------------------------
    mkdir -p /home/user/.ssh; \
    ssh-keyscan -t ed25519,rsa github.com  >> /home/user/.ssh/known_hosts 2>/dev/null; \
    ssh-keyscan -t ed25519,rsa gitlab.com  >> /home/user/.ssh/known_hosts 2>/dev/null; \
    chmod 700 /home/user/.ssh; \
    chmod 644 /home/user/.ssh/known_hosts; \
    \
    # -- Also populate /etc/skel for any future users -------------------------
    cp -r /home/user/.ssh   /etc/skel/.ssh; \
    mkdir -p /etc/skel/.npm-global; \
    \
    # -- bashrc defaults ------------------------------------------------------
    { \
        echo ''; \
        echo '# npm global path'; \
        echo 'export PATH="$HOME/.npm-global/bin:$PATH"'; \
        echo ''; \
        echo '# Aliases'; \
        echo 'alias cld="claude --dangerously-skip-permissions"'; \
    } | tee -a /home/user/.bashrc >> /etc/skel/.bashrc; \
    \
    # -- Fix ownership of user home directory ---------------------------------
    chown -R user:user /home/user; \
    \
    # -- Cleanup to minimise image size ---------------------------------------
    apt-get clean; \
    rm -rf \
        /var/lib/apt/lists/* \
        /var/cache/apt/* \
        /tmp/* \
        /var/tmp/* \
        /usr/share/doc/* \
        /usr/share/man/* \
        /root/.npm \
    ;

# =============================================================================
# Final stage: single-layer image
# =============================================================================
FROM scratch
COPY --from=builder / /

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
