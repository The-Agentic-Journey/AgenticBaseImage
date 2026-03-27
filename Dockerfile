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
        # Python
        python3 \
        python3-pip \
        python3-venv \
        # Node.js (for Playwright)
        nodejs \
        npm \
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
    echo 'LANG=en_US.UTF-8' > /etc/default/locale; \
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
    # -- tmux config -----------------------------------------------------------
    { \
        echo '# Use C-a as prefix (like screen)'; \
        echo 'set -g prefix C-a'; \
        echo 'unbind C-b'; \
        echo 'bind C-a send-prefix'; \
        echo ''; \
        echo '# Enable mouse support'; \
        echo 'set -g mouse on'; \
        echo ''; \
        echo '# Start windows and panes at 1, not 0'; \
        echo 'set -g base-index 1'; \
        echo 'setw -g pane-base-index 1'; \
        echo ''; \
        echo '# Renumber windows when one is closed'; \
        echo 'set -g renumber-windows on'; \
        echo ''; \
        echo '# Enable true color support'; \
        echo 'set -g default-terminal "tmux-256color"'; \
        echo 'set -ag terminal-overrides ",xterm-256color:RGB"'; \
        echo ''; \
        echo 'set -sg escape-time 0'; \
        echo ''; \
        echo '# Reload config with r'; \
        echo 'bind r source-file ~/.tmux.conf \; display "Config reloaded!"'; \
        echo ''; \
        echo '# Switch panes using Alt-arrow without prefix'; \
        echo 'bind -n M-Left select-pane -L'; \
        echo 'bind -n M-Right select-pane -R'; \
        echo 'bind -n M-Up select-pane -U'; \
        echo 'bind -n M-Down select-pane -D'; \
        echo ''; \
        echo '# Increase scrollback buffer size'; \
        echo 'set -g history-limit 10000000'; \
        echo ''; \
        echo '# Status bar styling'; \
        echo 'set -g status-bg colour234'; \
        echo 'set -g status-fg colour137'; \
        echo "set -g status-left '#[fg=colour243][#(hostname)]  #[default]'"; \
        echo "set -g status-right '#[fg=colour233,bg=colour241,bold] %d/%m #[fg=colour233,bg=colour245,bold] %H:%M:%S '"; \
        echo 'set -g status-right-length 70'; \
        echo 'set -g status-left-length 30'; \
    } | tee /home/user/.tmux.conf > /etc/skel/.tmux.conf; \
    \
    # -- Claude Code statusline config ------------------------------------------
    mkdir -p /home/user/.claude; \
    { \
        echo '#!/bin/bash'; \
        echo 'input=$(cat)'; \
        echo 'MODEL=$(echo "$input" | jq -r '\''.model.display_name // "Claude"'\'')'; \
        echo 'PCT=$(echo "$input" | jq -r '\''.context_window.used_percentage // 0'\'' | cut -d. -f1)'; \
        echo 'COST=$(echo "$input" | jq -r '\''.cost.total_cost_usd // 0'\'')'; \
        echo 'echo "[$MODEL] ctx:${PCT}% \$$COST"'; \
    } > /home/user/.claude/statusline.sh; \
    chmod +x /home/user/.claude/statusline.sh; \
    echo '{"statusLine":{"type":"command","command":"~/.claude/statusline.sh","padding":2}}' \
        > /home/user/.claude/settings.json; \
    cp -r /home/user/.claude /etc/skel/.claude; \
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
