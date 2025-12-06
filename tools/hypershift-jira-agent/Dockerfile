FROM registry.ci.openshift.org/ocp/builder:rhel-9-golang-1.24-openshift-4.21

# Install required tools
RUN dnf install -y \
    jq \
    git \
    curl \
    nodejs \
    npm \
    python3 \
    python3-pip \
    && dnf clean all

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo | tee /etc/yum.repos.d/github-cli.repo && \
    dnf install -y gh && \
    dnf clean all

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Install Python dependencies for MCP servers
RUN pip3 install --no-cache-dir \
    requests \
    pyyaml

# Clone ai-helpers repository for plugins
RUN git clone https://github.com/openshift-eng/ai-helpers.git /opt/ai-helpers

# Create claude user for proper permissions
RUN useradd -m -u 1000 -s /bin/bash claude

# Configure git defaults
RUN git config --global user.name "OpenShift CI Bot" && \
    git config --global user.email "ci-bot@redhat.com"

# Create Claude configuration directory with plugins enabled
RUN mkdir -p /home/claude/.claude/plugins && \
    chown -R claude:claude /home/claude/.claude

# Copy Claude settings with ai-helpers plugins enabled
COPY claude-settings.json /home/claude/.claude/settings.json
RUN chown claude:claude /home/claude/.claude/settings.json

# Create workspace directory
RUN mkdir -p /tmp/hypershift && chown -R claude:claude /tmp/hypershift

# Verify installations
RUN claude --version && \
    gh --version && \
    jq --version && \
    git --version

WORKDIR /tmp

# The actual scripts will be mounted from step-registry at runtime
