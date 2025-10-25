FROM quay.io/openshift/origin-cli:latest

# Install required tools
RUN yum install -y \
    jq \
    git \
    curl \
    nodejs \
    npm \
    && yum clean all

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo | tee /etc/yum.repos.d/github-cli.repo && \
    yum install -y gh && \
    yum clean all

# Install Claude Code CLI
RUN npm install -g @anthropics/claude-code

# Configure git defaults
RUN git config --global user.name "OpenShift CI Bot" && \
    git config --global user.email "ci-bot@redhat.com"

# Verify installations
RUN claude --version && \
    gh --version && \
    jq --version && \
    git --version

WORKDIR /tmp

# The actual scripts will be mounted from step-registry at runtime
