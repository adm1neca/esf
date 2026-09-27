# Machinist + Ollama in Docker

Runs the Machinist control plane, one managed worker, and the pinned OpenCode V2
agent in a single container. The agent uses an Ollama model, either on your
host or in a second container. This works on Windows (Docker Desktop with the
WSL 2 backend), macOS, and Linux.

```text
browser ──► localhost:7331 ──► [ container: control plane ─ worker ─ opencode2 ] ──► Ollama /v1
                                              │
                                   /workspace (your repositories)
```

## What this is and is not

This stack runs the **Machinist** layer of ESF. The **factory** worker
(`factory run`) needs CubeSandbox microVMs and Temporal and does not run here.
Without CubeSandbox, the agent has no microVM: it runs inside this container
with `--auto` permissions and can modify anything in the mounted workspace.
Mount only the repositories you want it to change, and review its branches
before merging. Commits stay local; nothing is pushed.

## 1. Prepare Ollama

Pick a model with tool-calling support that fits your GPU. `qwen3-coder:30b` is
the default. `gpt-oss:20b` is a smaller alternative. Coding agents need a long
context window, so set it to at least 32k.

**Option A: Ollama on the host (default).** The container reaches it at
`host.docker.internal:11434`. Ollama must accept connections that are not from
loopback:

- Windows: open *Settings → Environment Variables*, set the user variables
  `OLLAMA_HOST=0.0.0.0:11434` and `OLLAMA_CONTEXT_LENGTH=32768`, then quit and
  restart Ollama from the tray. Allow the Windows Firewall prompt for private
  networks.
- macOS: `launchctl setenv OLLAMA_HOST 0.0.0.0:11434` and
  `launchctl setenv OLLAMA_CONTEXT_LENGTH 32768`, then restart Ollama.
- Linux (systemd): run `sudo systemctl edit ollama` and add
  `Environment="OLLAMA_HOST=0.0.0.0:11434"` and
  `Environment="OLLAMA_CONTEXT_LENGTH=32768"` under `[Service]`, then
  `sudo systemctl restart ollama`.

Then pull the model with `ollama pull qwen3-coder:30b`.

Binding to `0.0.0.0` exposes Ollama to your local network, and Ollama has no
authentication. Keep the host firewall closed to other machines.

**Option B: Ollama in Docker.** Nothing to install. `compose.ollama.yaml` adds
an `ollama` container, pulls the configured model(s) into a volume on first
start, and points Machinist at it. On an NVIDIA GPU, also add
`compose.gpu.yaml`. On Windows this needs a current NVIDIA driver and Docker
Desktop's WSL 2 backend. On Linux it needs the NVIDIA Container Toolkit. Without
a GPU, models run on the CPU and are slow.

## 2. Configure

Run everything from the repository root. PowerShell and bash work the same way.

```sh
cp deployments/docker-ollama/.env.example deployments/docker-ollama/.env
```

Edit `.env`. At minimum, set `WORKSPACE_DIR` to a folder that contains Git
repositories, for example `C:/Users/you/code` on Windows. Every Git repository
**directly** inside that folder is registered with the worker under its folder
name, such as `C:/Users/you/code/my-app` → `my-app`. Leave `WORKSPACE_DIR`
unset to use `deployments/docker-ollama/workspace/`, which Git ignores.

On Windows, keep the repositories on the Windows drive, or for better I/O
inside a WSL distro such as `\\wsl$\Ubuntu\home\you\code`. Clone them with
`core.autocrlf=input` or `false` so the agent sees the same line endings as
your CI.

## 3. Start

Ollama on the host:

```sh
docker compose -f deployments/docker-ollama/compose.yaml up -d --build
```

Ollama in Docker (add `-f deployments/docker-ollama/compose.gpu.yaml` for NVIDIA):

```sh
docker compose -f deployments/docker-ollama/compose.yaml -f deployments/docker-ollama/compose.ollama.yaml up -d --build
```

Check the startup log:

```sh
docker logs esf-machinist
```

You should see each registered repository, `Ollama reachable at ...`, and
`worker docker-ollama connecting`. If a model is missing, the log says which
`ollama pull` to run.

Open <http://localhost:7331>. The port is published on the host's loopback only.

## 4. Run a task

From the web UI, choose a repository and a command. Or from the command line:

```sh
docker exec esf-machinist machinist submit \
  --config /home/machinist/.machinist/worker.generated.toml \
  --repo my-app --command code \
  --prompt "Add input validation to the signup form and a test for it"
```

| Command / workflow | Behavior |
| --- | --- |
| `code` | Creates a `machinist/<name>` branch, makes the change, runs checks, and commits locally. It never pushes. |
| `ask` | Sends your prompt to the agent unchanged. |
| `plan_then_code` | Runs `ask`, then waits for your approval before `code`. |

To use a different pulled model for one task, add
`--model ollama/<model>`. The model must be listed in `OLLAMA_MODEL` or
`OLLAMA_MODELS`.

## Changing things

| To... | Do this |
| --- | --- |
| Add a repository | Clone it into `WORKSPACE_DIR`, then `docker restart esf-machinist` |
| Change or add models | Edit `OLLAMA_MODEL`/`OLLAMA_MODELS` in `.env`, then `up -d` again |
| Use your own commands, prompts, or worker | Put `config.toml` (with its `prompts/`), `worker.toml`, or `opencode.json` in `deployments/docker-ollama/overrides/`. They replace the generated files. |
| Push branches or open PRs | Mount credentials yourself, such as a deploy key under `/home/machinist/.ssh`, and change the prompt. Pushing is off by default. |
| Stop | `docker compose -f deployments/docker-ollama/compose.yaml down` |
| Reset jobs and token | `down -v` also deletes the `esf-machinist-state` volume. With the Ollama overlay it also deletes pulled models. |

## Troubleshooting

- **`Ollama is not reachable`**: Ollama on the host is still bound to
  `127.0.0.1`, or a firewall blocks it. Check with
  `docker exec esf-machinist curl -s http://host.docker.internal:11434/api/tags`.
- **The agent loops, stops early, or never edits files**: the context window is
  too small or the model is weak at tool calling. Raise
  `OLLAMA_CONTEXT_LENGTH` or pick a stronger coding model.
- **`no repositories registered`**: the repositories are nested too deep, or
  their folder names contain characters other than letters, digits, `.`, `_`,
  and `-`.
- **`dubious ownership` from Git**: the entrypoint marks every directory as
  safe. If you replaced the worker, run
  `git config --global --add safe.directory '*'` in the container.
- **Permission denied writing to a repository on Linux**: the container runs as
  UID 1000. Match it with `sudo chown -R 1000:1000 <repo>`.
- **`env: bash\r: No such file or directory`**: the entrypoint was checked out
  with CRLF line endings. `.gitattributes` forces LF here: delete
  `deployments/docker-ollama/entrypoint.sh`, run
  `git checkout -- deployments/docker-ollama/entrypoint.sh`, and rebuild.
