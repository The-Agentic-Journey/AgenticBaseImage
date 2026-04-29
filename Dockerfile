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
        echo '#!/usr/bin/env bash'; \
        echo 'input=$(cat)'; \
        echo ''; \
        echo 'cwd=$(echo "$input" | jq -r '\''.workspace.current_dir // .cwd // empty'\'')'; \
        echo 'model=$(echo "$input" | jq -r '\''.model.display_name // empty'\'')'; \
        echo 'used=$(echo "$input" | jq -r '\''.context_window.used_percentage // empty'\'')'; \
        echo ''; \
        echo '# Shorten home directory to ~'; \
        echo 'home="$HOME"'; \
        echo 'short_cwd="${cwd/#$home/\~}"'; \
        echo ''; \
        echo '# Get git branch, skip optional locks'; \
        echo 'git_branch=""'; \
        echo 'if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree > /dev/null 2>&1; then'; \
        echo '  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)'; \
        echo 'fi'; \
        echo ''; \
        echo '# Build status line'; \
        echo 'parts="$short_cwd"'; \
        echo ''; \
        echo 'if [ -n "$git_branch" ]; then'; \
        echo '  parts="$parts  $git_branch"'; \
        echo 'fi'; \
        echo ''; \
        echo 'if [ -n "$used" ]; then'; \
        echo '  printf -v used_fmt "%.0f" "$used" 2>/dev/null || used_fmt="$used"'; \
        echo '  parts="$parts  ctx:${used_fmt}%"'; \
        echo 'fi'; \
        echo ''; \
        echo 'if [ -n "$model" ]; then'; \
        echo '  parts="$parts  $model"'; \
        echo 'fi'; \
        echo ''; \
        echo 'printf '\''%s'\'' "$parts"'; \
    } > /home/user/.claude/statusline-command.sh; \
    chmod +x /home/user/.claude/statusline-command.sh; \
    echo '{"statusLine":{"type":"command","command":"~/.claude/statusline-command.sh","padding":2}}' \
        > /home/user/.claude/settings.json; \
    echo '{"hasCompletedOnboarding":true,"numStartups":1}' > /home/user/.claude.json; \
    cp -r /home/user/.claude /etc/skel/.claude; \
    cp /home/user/.claude.json /etc/skel/.claude.json; \
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
