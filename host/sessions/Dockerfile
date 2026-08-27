FROM mcr.microsoft.com/playwright:v1.49.0-jammy

ARG USER_UID=1000
ARG USER_GID=1000

# ---- System deps ----
RUN apt-get update && apt-get install -y \
    curl wget git tmux vim sudo openssh-client gnupg lsb-release \
    build-essential python3 python3-pip python3-venv python3-dev \
    postgresql-client redis-tools \
    jq ripgrep fd-find httpie unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* && \
    # Ubuntu names fd-find binary `fdfind`; alias it to the conventional `fd`
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd

# ---- yq (Go binary, more capable than the pip yq) ----
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
      -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# ---- uv (fast Python package manager) ----
RUN curl -LsSf https://astral.sh/uv/install.sh | \
    UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh

# ---- Node 22 LTS ----
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# ---- GitHub CLI ----
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# ---- AWS CLI v2 ----
RUN curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# ---- Match host UID so mounted volumes work ----
RUN groupmod -g ${USER_GID} pwuser && \
    usermod -u ${USER_UID} pwuser && \
    echo "pwuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER pwuser
WORKDIR /home/pwuser

# ---- Global npm tools ----
ENV NPM_CONFIG_PREFIX=/home/pwuser/.npm-global
ENV PATH=/home/pwuser/.npm-global/bin:$PATH
RUN mkdir -p /home/pwuser/.npm-global && \
    npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex \
        @google/gemini-cli \
        opencode-ai \
        vercel \
        @railway/cli \
        pnpm yarn

# ---- Supabase CLI (installed via official binary, npm not supported) ----
USER root
RUN ARCH=$(dpkg --print-architecture) && \
    DEB_URL=$(curl -sL https://api.github.com/repos/supabase/cli/releases/latest | grep -oE "\"browser_download_url\":[^,]+" | grep "linux_${ARCH}\.deb\"" | head -1 | sed -E 's/.*"(https[^"]+)".*/\1/') && \
    curl -sLo /tmp/supabase.deb "$DEB_URL" && \
    dpkg -i /tmp/supabase.deb && \
    rm /tmp/supabase.deb
USER pwuser

# ---- Playwright browsers + agents ----
ENV PLAYWRIGHT_BROWSERS_PATH=/home/pwuser/.cache/ms-playwright
RUN npx playwright install chromium firefox webkit

# ---- Pre-cache tiktoken (the failure Veri specifically flagged) ----
ENV TIKTOKEN_CACHE_DIR=/home/pwuser/.cache/tiktoken
RUN pip3 install --user tiktoken && \
    mkdir -p $TIKTOKEN_CACHE_DIR && \
    python3 -c "import tiktoken; \
        [tiktoken.get_encoding(e) for e in \
         ['cl100k_base', 'p50k_base', 'r50k_base', 'o200k_base']]"

# ---- Pre-install pip-audit ----
RUN pip3 install --user pip-audit

# ---- graphify (knowledge graph over a repo; agents query it instead of reading files -> saves tokens) ----
# tree-sitter AST parsing is local + LLM-free. `graphify .` builds graphify-out/graph.json;
# `graphify query/path/explain` answer from it. The OpenCode skill (installed on the cc-config
# volume) nudges the agent to query the graph before opening files.
ENV PATH=/home/pwuser/.local/bin:$PATH
RUN uv tool install graphifyy

# ---- Codex CLI (@openai/codex): pin to latest (npm ships frequent updates; late layer = fast rebuild) ----
RUN npm install -g @openai/codex@latest

# ---- Convenience wrappers for "skip permissions" / yolo modes ----
USER root
RUN printf '#!/bin/bash\nexec claude --dangerously-skip-permissions "$@"\n' > /usr/local/bin/ccd && chmod +x /usr/local/bin/ccd && \
    printf '#!/bin/bash\nexec codex --dangerously-bypass-approvals-and-sandbox "$@"\n' > /usr/local/bin/cxd && chmod +x /usr/local/bin/cxd && \
    printf '#!/bin/bash\nexec gemini --yolo "$@"\n' > /usr/local/bin/gmd && chmod +x /usr/local/bin/gmd && \
    printf '#!/bin/bash\n# ocd — OpenCode auto-approve; forwards OPENCODE_MODE->--agent, OPENCODE_MODEL->--model\nexec opencode --auto ${OPENCODE_MODE:+--agent "$OPENCODE_MODE"} ${OPENCODE_MODEL:+--model "$OPENCODE_MODEL"} "$@"\n' > /usr/local/bin/ocd && chmod +x /usr/local/bin/ocd
USER pwuser

# ---- Persistent dirs (mounted as named volumes at runtime) ----
RUN mkdir -p /home/pwuser/.claude /home/pwuser/.codex /home/pwuser/.gemini \
    /home/pwuser/.config /home/pwuser/.opencode /home/pwuser/.ssh /home/pwuser/.npm /home/pwuser/work

# ---- Helpful shell defaults ----
RUN echo 'alias ll="ls -la"' >> /home/pwuser/.bashrc && \
    echo 'alias gs="git status"' >> /home/pwuser/.bashrc && \
    echo 'cd /home/pwuser/work' >> /home/pwuser/.bashrc

CMD ["/bin/bash"]

# --- Android build support (HSK app) ---
USER root
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-17-jdk-headless unzip && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk
RUN mkdir -p $ANDROID_HOME/cmdline-tools && cd $ANDROID_HOME/cmdline-tools && \
    curl -fsSL -o tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip && \
    unzip -q tools.zip && mv cmdline-tools latest && rm tools.zip && \
    yes | latest/bin/sdkmanager --licenses >/dev/null && \
    latest/bin/sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" && \
    chown -R pwuser:pwuser $ANDROID_HOME
ENV PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools
USER pwuser
