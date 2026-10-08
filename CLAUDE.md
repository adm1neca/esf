# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ESF (Engineering Software Factory) is a fork of [Machinist](https://github.com/owainlewis/machinist). The repository contains two products that share one Go module (`github.com/mitkox/esf`):

- **Machinist** (`cmd/machinist`, built with `just`): the inherited CLI, local control plane (HTTP + SQLite + embedded React UI), and managed worker. It runs staged jobs/workflows with review gates.
- **Factory** (`cmd/factory`, built with `make`): a Temporal-orchestrated layer. It runs coding agents in CubeSandbox microVMs, verifies their output with deterministic gates, and stores patches and evidence.

Read `ARCHITECTURE.md` first. The design rationale is in `docs/adr/`. Update `ARCHITECTURE.md` when boundaries or contracts change.

## Commands

The toolchains are pinned in `.mise.toml` (Go 1.27.1, Node 24.21.0, Python 3.14.8), and CI checks the Go version exactly. `.mise.toml` is the source of truth.

```sh
just check            # full pre-PR check (mirrors the required CI "check")
just build            # frontend build + bin/machinist
just local            # control plane (examples/config.toml) + managed worker
make build            # bin/factory + cube-* discovery tools
make lint             # gofmt -l (cmd, internal), go vet, shellcheck
make test             # go test ./... + frontend + optional Python tool tests
make test-unit        # go test ./internal/... ./cmd/...
go test -race ./...   # what CI runs on Linux and macOS
```

Run a single test:

```sh
go test ./internal/factory -run '^TestName$' -count=1 -v
cd internal/controlplane/web && npm test                       # node --test src/*.test.js
python3 -m unittest discover -s evals -p 'test_*.py'          # agent.py evals (fake Codex/gh)
node --test .github/scripts/issue-triage.test.cjs
```

Integration tests use the `//go:build integration` tag. They need a live CubeSandbox and/or Temporal (`make temporal-up`; the stack is in `deployments/dev/temporal`) and create real sandboxes: `make test-integration` and `make temporal-hello`. The default suite needs no Cube, Temporal, model credentials, and it must stay that way.

## Things that are easy to get wrong

- **The frontend bundle is committed.** `internal/controlplane/web/dist` is embedded into the Go binary. CI fails if it is stale. After changing `web/src`, run `npm ci && npm test && npm run build` in `internal/controlplane/web` and commit the `dist` output.
- **Platform build tags.** `cmd/machinist/main.go` and `internal/runner/process_unix.go` are `darwin || linux` only. `cmd/factory/storage_linux.go` is Linux-only and has a `storage_other.go` (`!linux`) fallback. Machinist does not build natively on Windows; on Windows use `deployments/docker-ollama` (Docker + Ollama).
- **Temporal determinism.** Workflow code in `internal/factory` must not resolve config names. `resources.go` resolves `[workspaces]`, `[models]`, `[egress]`, `[budgets]` and `[scopes]` exactly once, in the validation activity. Scopes may narrow global policy but never widen it. Behaviour changes to existing workflows need Temporal workflow versioning so that existing histories still replay.
- **Harnesses are selected by name only.** Callers never supply executables or argv (`internal/agentharness`, which includes an opt-in Pi durable harness). `{{model_args}}` is substituted into a harness's fixed args, because agent CLIs place the model flag in different positions.
- **Sandbox capabilities are optional.** `internal/sandbox/lifecycle.go` defines `Suspender`, `Previewer` and `Stater`. When a provider lacks one, record `SKIPPED` with a reason; never claim the step happened.
- **GitHub Actions** must be pinned to a full commit SHA with a `# vX.Y.Z` comment. Never replace a pin with a mutable tag.
- Use Conventional Commits. Changes to `main` go through a PR and must pass the `check` status.

## Architecture map

- `internal/runner`: starts one process per repository, writes the prompt to stdin, streams output, records artifacts and token usage (Codex/Claude parsers), and kills the process tree on timeout.
- `internal/controlplane`: jobs, step attempts, immutable artifacts, review gates and execution leases. It rejects stale completions and serves the authenticated API and UI. SQLite schema migrations (2→5) take a backup first.
- `internal/managedworker`: resolves only worker-owned executor and repository names from `~/.machinist/worker.toml`.
- `internal/config`: strict TOML loading (`config.toml` holds commands, prompts, triggers and the server; `worker.toml` holds approved executors and repository paths).
- `internal/factory`: Temporal workflows and activities. `change.go` holds the durable `Change` work item; runs are activations of it, and aggregates are recomputed from run manifests. `inventory.go` writes the harness contract into the sandbox. `workflow.go` handles per-step conditions and the review pause (`review-decision` signal).
- `internal/sandbox` (+ `cube/`): the sandbox abstraction and its CubeSandbox provider. `fake.go` is used in tests.
- `internal/verification`: deterministic gate profiles. The default profile expects repository-owned `build.sh` and `test.sh` scripts.
- `agent.py`: a standalone uv script that runs the GitHub issue→PR workflow using Codex/Claude adapters. It is tested by `evals/`.
- `tools/intake` and `tools/brief_lab`: optional Python tools that use the frozen `uv.lock`.
- `deploy/` (Helm, systemd, images) and `deployments/` (dev Temporal, docker-ollama): deployment assets. `release/` holds the release inventory and qualifications that CI checks.
