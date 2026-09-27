# Machinist control plane + managed worker + OpenCode V2, talking to Ollama.
#
# Development image for running ESF's Machinist layer in Docker (for example on
# Windows through Docker Desktop). It does NOT include the CubeSandbox factory:
# agents run inside this container, which is the isolation boundary.
#
# Build from the repository root:
#   docker compose -f deployments/docker-ollama/compose.yaml build

ARG GO_BUILDER=docker.io/library/golang@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195
ARG NODE_BUILDER=docker.io/library/node:24.21.0-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6
ARG RUNTIME_BASE=docker.io/library/debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

FROM --platform=$BUILDPLATFORM ${GO_BUILDER} AS machinist
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETOS
ARG TARGETARCH
ARG ESF_VERSION=0.5.0
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -buildvcs=false -trimpath -ldflags="-s -w -X main.version=v${ESF_VERSION}" \
      -o /out/machinist ./cmd/machinist

# npm ci verifies every tarball against agents/opencode/package-lock.json.
# On amd64 the binary is also checked against the qualified release digest.
FROM ${NODE_BUILDER} AS opencode
WORKDIR /agents/opencode
COPY agents/opencode/package.json agents/opencode/package-lock.json ./
COPY release/inventory.json /release/inventory.json
ARG TARGETARCH
RUN npm ci --no-audit --no-fund && \
    install -m 0755 node_modules/@opencode/cli/bin/opencode.exe /out-opencode2 && \
    if [ "$TARGETARCH" = amd64 ]; then \
      expected=$(node -p 'require("/release/inventory.json").dependencies.opencode.linux_amd64_binary_sha256') && \
      echo "$expected  /out-opencode2" | sha256sum -c -; \
    fi

FROM ${RUNTIME_BASE}
# Toolchains the agent needs to build and test your repositories, for example
# "build-essential python3 python3-venv golang". Empty keeps the image small.
ARG EXTRA_APT_PACKAGES=""
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git openssh-client socat tini ${EXTRA_APT_PACKAGES} && \
    rm -rf /var/lib/apt/lists/*
COPY --from=machinist /out/machinist /usr/local/bin/machinist
COPY --from=opencode /out-opencode2 /usr/local/bin/opencode2
COPY deployments/docker-ollama/config /opt/esf-docker/config
COPY --chmod=0755 deployments/docker-ollama/entrypoint.sh /usr/local/bin/esf-docker-entrypoint
COPY --chmod=0755 deployments/docker-ollama/opencode-step.sh /usr/local/bin/opencode-step

# Match your Linux user's UID/GID so bind-mounted repositories stay writable.
# Docker Desktop on Windows/macOS maps bind-mount ownership, so the default is
# fine there.
ARG UID=1000
ARG GID=1000
RUN groupadd --gid "${GID}" machinist && \
    useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash machinist && \
    install -d -o machinist -g machinist /workspace /home/machinist/.machinist
USER machinist
WORKDIR /workspace
ENV HOME=/home/machinist

# The loopback-only control plane is forwarded to this port (entrypoint.sh).
EXPOSE 7332
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/esf-docker-entrypoint"]
