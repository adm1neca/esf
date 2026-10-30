# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ESF (Engineering Software Factory) is a Temporal-orchestrated software factory (Go module `github.com/mitkox/esf`). It runs coding agents in CubeSandbox microVMs, verifies their output with deterministic gates, and stores patches and evidence on the factory host. This repository is a fork of [mitkox/esf](https://github.com/mitkox/esf). ESF itself began as a fork of Machinist; the inherited `machinist` CLI, control plane and managed worker were removed upstream in 0.6.2 (see `docs/adr/0008-remove-machinist.md`).

Read `ARCHITECTURE.md` first. The design rationale is in `docs/adr/`. Update `ARCHITECTURE.md` when boundaries or contracts change.

## Commands

The toolchains are pinned in `.mise.toml`, and CI checks the Go version exactly. `.mise.toml` is the source of truth.

```sh
make build            # bin/factory + cube-* discovery tools
make console-build    # build the embedded console SPA, then bin/factory
make lint             # gofmt -l (cmd, internal), go vet, shellcheck
make test             # go test ./... + console frontend + optional Python + Temporal schema tests
make test-unit        # go test ./internal/... ./cmd/...
go test -race ./...   # what CI runs on Linux and macOS
make help             # every target
```

Run a single test:

```sh
go test ./internal/factory -run '^TestName$' -count=1 -v
cd internal/console/web && npm test
node --test .github/scripts/issue-triage.test.cjs
```

Integration tests use the `//go:build integration` tag. They need a live CubeSandbox and/or Temporal (`make temporal-up`; the stack is in `deployments/dev/temporal`) and create real sandboxes: `make test-integration` and `make temporal-hello`. The default suite needs no Cube, Temporal, model credentials, and it must stay that way.

## Things that are easy to get wrong

- **The console bundle is committed.** `internal/console/web/dist` is embedded into the Go binary. CI fails if it is stale. After changing `web/src`, run `npm ci && npm test && npm run build` in `internal/console/web` and commit the `dist` output.
- **Platform build tags.** `cmd/factory/storage_linux.go` is Linux-only and has a `storage_other.go` (`!linux`) fallback.
- **Temporal determinism.** Workflow code in `internal/factory` must not resolve config names. `resources.go` resolves `[workspaces]`, `[models]`, `[egress]`, `[budgets]` and `[scopes]` exactly once, in the validation activity. Scopes may narrow global policy but never widen it. Behaviour changes to existing workflows need Temporal workflow versioning so that existing histories still replay.
- **Harnesses are selected by name only.** Callers never supply executables or argv (`internal/agentharness`, which includes an opt-in Pi durable harness). `{{model_args}}` is substituted into a harness's fixed args, because agent CLIs place the model flag in different positions.
- **Sandbox capabilities are optional.** `internal/sandbox/lifecycle.go` defines `Suspender`, `Previewer` and `Stater`. When a provider lacks one, record `SKIPPED` with a reason; never claim the step happened.
- **GitHub Actions** must be pinned to a full commit SHA with a `# vX.Y.Z` comment. Never replace a pin with a mutable tag.
- Use Conventional Commits. Changes to `main` go through a PR and must pass the `check` status.

## Architecture map

- `cmd/factory`: the `factory` CLI, the control plane and security boundary. It accepts only an approved repository, an exact revision and task text.
- `internal/factory`: Temporal workflows and activities. `change.go` holds the durable `Change` work item; runs are activations of it, and aggregates are recomputed from run manifests. `inventory.go` writes the harness contract into the sandbox. `workflow.go` handles per-step conditions and the review pause (`review-decision` signal).
- `internal/console` (+ `web/`): the factory console server and its embedded SPA.
- `internal/sandbox` (+ `cube/`): the sandbox abstraction and its CubeSandbox provider. `fake.go` is used in tests.
- `internal/verification`: deterministic gate profiles. The default profile expects repository-owned `build.sh` and `test.sh` scripts.
- `internal/factoryartifacts`: runs, changes, patches and evidence under `.factory/`.
- `internal/repository`: prepares the exact revision inside the sandbox. `internal/threatmon` quarantines out-of-bounds agent behaviour.
- `cmd/turn-executor` and `internal/turnexec`: the private sf turn service (`docs/sf-turn-executor.md`).
- `agents/` (opencode, pi): pinned agent runner assets.
- `tools/cube-*`: CubeSandbox discovery and smoke tools. `tools/intake` and `tools/brief_lab`: optional Python tools that use the frozen `uv.lock`.
- `deploy/` (Helm, systemd, images) and `deployments/dev` (Temporal): deployment assets. `release/` holds the release inventory and qualifications that CI checks.
