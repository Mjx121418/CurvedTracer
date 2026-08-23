FROM swift:6.3.3-noble

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies for the repo and DeepSeek Harness.
# Keep build-essential for libstdc++/system headers used by clang.
# Deliberately do NOT install Ubuntu's clang-18 package: it shadows the Swift
# toolchain clang-21 and rejects SwiftPM's -index-store-path flag.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    ca-certificates \
    build-essential \
    pkg-config \
    python3 \
    ripgrep \
    jq \
    tree \
    socat \
    && rm -rf /var/lib/apt/lists/*

# Node.js, needed by DeepSeek Harness
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get update \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# DeepSeek Harness
RUN npm install -g @deepseek-ai/dsh

# Codex CLI
RUN npm install -g @openai/codex

WORKDIR /workspace

CMD ["/bin/bash"]
