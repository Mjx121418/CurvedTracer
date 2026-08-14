FROM swift:6.3.3-noble

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    ca-certificates \
    build-essential \
    clang \
    clang-format \
    clang-tidy \
    lldb \
    cmake \
    ninja-build \
    pkg-config \
    python3 \
    ripgrep \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Node.js, needed by DeepSeek Harness
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get update \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# DeepSeek Harness
RUN npm install -g @deepseek-ai/dsh

RUN apt-get update \
    && apt-get install -y --no-install-recommends socat \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["/bin/bash"]
