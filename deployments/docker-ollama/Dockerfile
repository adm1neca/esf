# Machinist control plane + managed worker + OpenCode V2, talking to Ollama.
#
# Development image for running ESF's Machinist layer in Docker (for example on
# Windows through Docker Desktop). It does NOT include the CubeSandbox factory:
# agents run inside this container, which is the isolation boundary.
#
# Build from the repository root:
#   docker compose -f deployments/docker-ollama/compose.yaml build

ARG GO_BUILDER=docker.io/library/golang@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195
ARG NODE_BUILDER=docker.io/library/node:24.21.0-bookworm-slim
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
FROM ${NODE_BUILDER} AS opencode
WORKDIR /agents/opencode
COPY agents/opencode/package.json agents/opencode/package-lock.json ./
RUN npm ci --no-audit --no-fund && \
    install -m 0755 node_modules/@opencode/cli/bin/opencode.exe /out-opencode2

FROM ${RUNTIME_BASE}
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git openssh-client socat tini && \
    rm -rf /var/lib/apt/lists/*
COPY --from=machinist /out/machinist /usr/local/bin/machinist
COPY --from=opencode /out-opencode2 /usr/local/bin/opencode2
COPY deployments/docker-ollama/config /opt/esf-docker/config
COPY --chmod=0755 deployments/docker-ollama/entrypoint.sh /usr/local/bin/esf-docker-entrypoint

# UID 1000 usually matches the first user on a Linux host, which keeps bind
# mounted repositories writable. Docker Desktop on Windows/macOS maps ownership
# for bind mounts, so the value does not matter there.
RUN groupadd --gid 1000 machinist && \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash machinist && \
    install -d -o machinist -g machinist /workspace /home/machinist/.machinist
USER machinist
WORKDIR /workspace
ENV HOME=/home/machinist

EXPOSE 7331
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/esf-docker-entrypoint"]
