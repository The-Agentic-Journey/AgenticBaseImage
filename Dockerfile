# =============================================================================
# Firecracker Base Image - Single Layer Debian
# =============================================================================
# Uses multi-stage build with FROM scratch to produce exactly one layer.
#
# Stage 1 (builder): Install everything on top of debian:bookworm-slim
# Stage 2 (final):   COPY the entire filesystem into a scratch image -> 1 layer
# =============================================================================

FROM debian:bookworm-slim AS builder

# Pinned third-party versions. Bump these to upgrade.
ARG NVM_VERSION=v0.40.1
ARG NODE_VERSION=v24.15.0
ARG PLAYWRIGHT_VERSION=1.59.1

# Shared system-wide Playwright browser cache. Set in both stages so it is in
# scope for `npx playwright install` during the build AND for any user running
# Playwright at runtime — without this, browsers go to /root/.cache and the
# `user` account silently re-downloads them on first use.
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/ms-playwright

# Config files live in ./config/ (non-hidden filenames) and are copied into a
# scratch staging dir, then `cp`'d to their final destinations inside the RUN
# block. The trailing `rm -rf /tmp/*` cleanup deletes the staging dir, so the
# final image contains only the files at their real destinations.
#
# NOTE on image checksum stability: every config file emitted by this build is
# byte-identical (content, mode, owner) to what the previous inline-heredoc
# approach produced — verified by extracting both images to tar and diffing.
# However, the overall image SHA still differs between any two builds (incl.
# rebuilding the unmodified Dockerfile) due to non-reproducibility that
# predates this refactor: directory mtimes baked in by apt, log filenames
# containing a wall-clock timestamp (flyctl, npm), and the `claude` CLI
# install rewriting /home/user/.claude.json with a generated userID and
# firstStartTime. The COPY refactor itself contributes zero additional drift.
COPY config/ /tmp/config/

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
        systemd \
        systemd-sysv \
        dbus \
        openssh-client \
        openssh-server \
        # Firecracker / Docker requirements
        docker.io \
        docker-compose \
        iptables \
        # Networking tools
        iproute2 \
        iputils-ping \
        mosh \
        # Entropy daemon for Firecracker VMs
        haveged \
        # Locale support
        locales \
        # Dev tools
        tmux \
        jq \
        unzip \
        procps \
        vim \
        wget \
        htop \
        tree \
        # Python
        python3 \
        python3-pip \
        python3-venv \
        pipx \
    ; \
    \
    # -- SSH server configuration -----------------------------------------------
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config; \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config; \
    sed -i 's/^#\?ListenAddress.*/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config; \
    grep -q "^ListenAddress" /etc/ssh/sshd_config || echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config; \
    rm -f /etc/systemd/system/sockets.target.wants/ssh.socket; \
    ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service; \
    ssh-keygen -A; \
    \
    # -- Locale (en_US.UTF-8) ---------------------------------------------------
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; \
    locale-gen; \
    cp /tmp/config/locale /etc/default/locale; \
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
    # -- systemd: enable haveged for entropy ------------------------------------
    ln -sf /lib/systemd/system/haveged.service \
        /etc/systemd/system/multi-user.target.wants/haveged.service; \
    \
    # -- systemd: enable serial console -----------------------------------------
    mkdir -p /etc/systemd/system/getty.target.wants; \
    ln -sf /lib/systemd/system/serial-getty@.service \
        /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service; \
    \
    # -- Create default user with docker group access -------------------------
    useradd -m -s /bin/bash -G docker,sudo user; \
    cp /tmp/config/sudoers-user /etc/sudoers.d/user; \
    \
    # -- npm global prefix (non-root installs) --------------------------------
    mkdir -p /home/user/.npm-global; \
    \
    # -- nvm + Node.js (instead of the distro's older nodejs/npm) ------------
    # nvm installs to $NVM_DIR; we symlink node/npm/npx into /usr/local/bin so
    # they are on PATH for non-login shells (and for the build steps below).
    # Interactive shells additionally source nvm via /etc/skel/.bashrc, which
    # exposes the `nvm` command itself for switching versions.
    export NVM_DIR=/usr/local/nvm; \
    mkdir -p "$NVM_DIR"; \
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
        | PROFILE=/dev/null bash; \
    set +u; . "$NVM_DIR/nvm.sh"; set -u; \
    nvm install "${NODE_VERSION}"; \
    nvm alias default "${NODE_VERSION}"; \
    node_bin="$NVM_DIR/versions/node/${NODE_VERSION}/bin"; \
    ln -sf "$node_bin/node" /usr/local/bin/node; \
    ln -sf "$node_bin/npm"  /usr/local/bin/npm; \
    ln -sf "$node_bin/npx"  /usr/local/bin/npx; \
    \
    # -- Playwright (global install + Chromium) -------------------------------
    # Browsers go under $PLAYWRIGHT_BROWSERS_PATH (set above) so they are
    # readable by every account, not just root.
    mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"; \
    npm install -g "playwright@${PLAYWRIGHT_VERSION}"; \
    npx playwright install-deps chromium; \
    npx playwright install chromium; \
    chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"; \
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
    # -- tmux config -----------------------------------------------------------
    cp /tmp/config/tmux.conf /home/user/.tmux.conf; \
    cp /tmp/config/tmux.conf /etc/skel/.tmux.conf; \
    \
    # -- Claude Code statusline config ------------------------------------------
    mkdir -p /home/user/.claude; \
    cp /tmp/config/claude/statusline-command.sh /home/user/.claude/statusline-command.sh; \
    chmod +x /home/user/.claude/statusline-command.sh; \
    cp /tmp/config/claude/settings.json /home/user/.claude/settings.json; \
    cp /tmp/config/claude.json /home/user/.claude.json; \
    cp -r /home/user/.claude /etc/skel/.claude; \
    cp /home/user/.claude.json /etc/skel/.claude.json; \
    \
    # -- bashrc defaults ------------------------------------------------------
    tee -a /home/user/.bashrc < /tmp/config/bashrc >> /etc/skel/.bashrc; \
    \
    # -- Fix ownership of user home directory ---------------------------------
    # Must happen before su - user, so the user can write to ~/.claude etc.
    chown -R user:user /home/user; \
    \
    # -- Claude Code CLI --------------------------------------------------------
    { \
        echo '#!/bin/bash'; \
        echo 'set -eux'; \
        echo 'curl -fsSL https://claude.ai/install.sh | bash'; \
        echo 'echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc'; \
    } > /tmp/install-claude.sh; \
    su - user -c "bash /tmp/install-claude.sh"; \
    rm -f /tmp/install-claude.sh; \
    \
    # -- 1Password CLI ----------------------------------------------------------
    arch="$(dpkg --print-architecture)"; \
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
        | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg; \
    echo "deb [arch=${arch} signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/${arch} stable main" \
        > /etc/apt/sources.list.d/1password.list; \
    mkdir -p /etc/debsig/policies/AC2D62742012EA22/; \
    curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
        > /etc/debsig/policies/AC2D62742012EA22/1password.pol; \
    mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22; \
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
        | gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends 1password-cli; \
    \
    # -- flyctl -----------------------------------------------------------------
    curl -fsSL https://fly.io/install.sh | FLYCTL_INSTALL=/usr/local sh; \
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
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/ms-playwright
