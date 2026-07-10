# macon — CLI reference

Local iOS CI runner. Watches Bitbucket/GitHub, checks out commits, runs your
`macon.yml`, and posts build status back — all on your Mac.

## Install

```sh
brew tap alimusawa313/macon https://github.com/alimusawa313/homebrew-macon
brew install macon
macon init          # verify the toolchain first
```

## Commands at a glance

```
macon version                     print the installed version
macon doctor | init [--check]     check toolchain, permissions, cloudflared, disk (--json)
macon sims <list|install|create>  list / install simulator runtimes (all Apple platforms)
macon lint [path]                 parse & summarize a macon.yml
macon validate [path]             validate a macon.yml or a macon-export.json
macon config <init|validate>      scaffold / check the portable config
macon pipelines [file.json]       list pipelines in an app export file
macon run [options] [path]        run one workflow once, here
macon watch [options]             watch a repo and build new commits (until Ctrl-C)
macon watch --config file.json    watch pipelines exported from the app
macon service <install|…>         run a watch as a launchd service
macon install-service […]         alias for `service install`
macon companion <devices|…>       manage companion-app (iPhone/iPad) pairings
macon completions <zsh|bash>      print shell completions

Remote control — talks to a running runner (the app's, or `watch --companion`):
macon status [--host H] [--json]  pipelines + builds on the runner
macon logs [pipeline] [--follow]  print or tail a build's log
macon trigger <pipeline> [--follow]   build the current head now
macon cancel [pipeline|build]     stop a running build
macon pair --host H --code C      pair this CLI with a remote runner
macon metrics                     print the runner's Prometheus metrics
```

---

## `macon doctor` / `macon init` — health check

Check that everything a runner needs is present; `init` also auto-installs the
Homebrew-managed ones.

```sh
macon doctor            # report everything (same as init --check)
macon init              # check + install missing (fastlane, SwiftLint, gitleaks, JDK, cloudflared)
macon doctor --json     # machine-readable; exits non-zero when something's missing
```

Checks: Homebrew · Xcode + Command Line Tools · git · Ruby/Bundler · fastlane ·
SwiftLint · gitleaks · JDK · cloudflared · simulators · **disk space** (warns
under 20 GB free — DerivedData eats it) · **TCC permissions** for the current
process (Screen Recording / Accessibility — only needed if this terminal serves
screen/control on a headless Mac; the desktop app holds its own grants).

---

## `macon sims` — simulator runtimes & devices

Inspect and manage the simulators your test matrix targets — for **iOS,
watchOS, tvOS, and visionOS** (macOS builds run natively, no simulator).

```sh
macon sims                                    # list runtimes + device types (all platforms)
macon sims install 18.1                       # iOS runtime (bare version ⇒ iOS)
macon sims install watchOS 11.2               # a watchOS runtime
macon sims install tvOS                        # latest tvOS runtime
macon sims create "iPhone 16" 18.1            # create an iOS device
macon sims create "Apple Watch Series 10 (46mm)" 11.2 watchOS
```

Note: macon *builds* any Apple platform already (it just runs your fastlane/
scripts) — these commands only manage the **simulators** for platforms that have
them. Use `sims list` to find exact `device`/`os` values for a
[test matrix](#test-matrix). `install` runs `xcodebuild -downloadPlatform`; if
your Xcode is too old for `-buildVersion`, add the runtime via
Xcode ▸ Settings ▸ Components instead.

---

## `macon lint` — inspect a pipeline file

```sh
macon lint                    # lints ./macon.yml
macon lint path/to/macon.yml
```

Prints the workflows, their steps, `before_run` chains, and triggers. Good for
catching YAML mistakes before a build.

### Test matrix

A step can fan out over combinations (e.g. device × OS) — useful for UI tests
across simulators. Each run gets `MACON_MATRIX_<KEY>` in its environment. All
combinations run; the step fails if any of them fails.

```yaml
workflows:
  test:
    steps:
      - name: UI Tests
        matrix:
          device: ["iPhone 16", "iPad Air"]
          os: ["17.5", "18.2"]          # → 4 runs
        script: bundle exec fastlane test device:"$MACON_MATRIX_DEVICE" os:"$MACON_MATRIX_OS"
```

(Combinations run sequentially, so simulators don't contend. If you'd rather one
`xcodebuild` invocation parallelize them, pass multiple `-destination` flags in
your fastlane lane instead.)

---

## `macon run` — run once

Run a single workflow in a repo directory and exit with its status code. Drops
cleanly into a git hook, cron, or another CI.

```sh
macon run [--workflow N] [--branch B] [--file macon.yml] [path]
```

| Flag | Meaning |
|---|---|
| `--workflow N` | which workflow to run (default: auto-pick from triggers) |
| `--branch B` | branch name to report to steps (default: current git branch) |
| `--file macon.yml` | pipeline file name (default: `macon.yml`) |
| `[path]` | repo directory (default: `.`) |

```sh
# run the "test" workflow in the current checkout
macon run --workflow test

# secrets come from the shell env
ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_CONTENT=… macon run --workflow beta
```

---

## `macon watch` — continuous CI

Poll (or receive webhooks) and build every new commit/PR. Runs until Ctrl-C.

### From flags (single repo)

```sh
macon watch --workspace WS --repo SLUG [options]
```

| Flag | Default | Meaning |
|---|---|---|
| `--provider bitbucket\|github` | `bitbucket` | git host |
| `--workspace WS` | — | Bitbucket workspace, or GitHub **owner/org** |
| `--repo SLUG` | — | repository name |
| `--branch B` | `main` | branch to watch |
| `--prs` | off | watch open PRs instead of a branch |
| `--pr-target B` | all | with `--prs`, only PRs targeting this branch |
| `--webhook` | off | push mode: listen for webhooks instead of polling |
| `--port N` | `8787` | webhook listen port |
| `--webhook-secret S` | none | require a secret (GitHub HMAC, or present in the URL path). Or env `MACON_WEBHOOK_SECRET` |
| `--timeout MINS` | none | cancel a build that runs longer than `MINS` minutes |
| `--every SECS` | `30` | poll interval (polling mode) |
| `--workflow N` | auto | workflow to run from the pipeline file |
| `--file macon.yml` | `macon.yml` | pipeline file to look for |
| `--dir PATH` | `~/macon-ci/<repo>` | checkout directory |
| `--no-status` | off | don't post build status back |
| `--email E` `--token T` | env | auth (see [Authentication](#authentication)) |
| `--companion` | off | serve the [companion app](#macon-companion--iphoneipad-app) (monitor builds + live logs) |
| `--companion-port N` | `8899` | companion server port |
| `--pair-ttl MIN` | `15` | pairing-code lifetime |
| `--pair-code CODE` | random | use a fixed pairing code instead of a random one |

### From an app export (multiple pipelines)

```sh
macon watch --config macon-export.json                    # watch them all
macon watch --config macon-export.json --pipeline "Name"  # just one
```

Each pipeline uses its own saved settings. Log lines are prefixed with the
pipeline name.

---

## `macon service` — run as a background service

Install a `watch` as a `launchd` LaunchAgent so it starts at login and restarts
on crash — the way to run macon unattended on an always-on Mac (or an EC2 Mac).

```sh
# install: everything after `install` is the watch command it will run
macon service install --config ~/macon-export.json
macon service install --provider github --workspace org --repo app --webhook --label ci

macon service status   [--label NAME]     # loaded? where are the logs?
macon service uninstall [--label NAME]    # stop and remove
```

`--label NAME` lets you run several (default label is `default`). Logs go to
`~/Library/Logs/macon/<label>.log`. Credentials/secrets present in your shell at
install time (`BITBUCKET_*`, `GITHUB_TOKEN`, `ASC_*`, `SLACK_URL`,
`MACON_WEBHOOK_SECRET`) are copied into the LaunchAgent so the service can build.

`macon install-service …` is an alias for `macon service install …` — the
one-liner for a headless runner (e.g. an EC2 Mac):

```sh
macon install-service --config macon-export.json --companion
```

---

## Remote control — `status` · `logs` · `trigger` · `cancel`

Drive a **running** runner from the terminal — the desktop app's companion
server, or a headless `macon watch --companion` (local or remote).

```sh
macon status                       # pipelines + builds (add --json for scripts)
macon logs                         # log of the live (or newest) build
macon logs "My App" --follow       # tail until it finishes; exit 0/1 by result
macon trigger "My App"             # build the current head now
macon trigger "My App" --follow    # …and wait for the verdict (CI gate)
macon cancel                       # stop whatever is running
```

| Flag | Meaning |
|---|---|
| `--host H[:P]` | target runner (default `localhost`); a tunnel domain works (HTTPS auto) |
| `--port P` | local port when `--host` is omitted (default `8899`) |
| `--token T` | bearer token (or env `MACON_TOKEN`) |
| `--json` | machine-readable output (`status`) |
| `--follow` | tail the build; exit `0` passed / `1` failed |

**Auth** is the same device token a paired iPhone uses:

- **Local runner** — nothing to do. The CLI pairs itself through the shared
  on-disk pairing store the first time and keeps the token in your Keychain.
- **Remote runner** (tunnel, EC2 Mac) — pair once with the code the runner
  prints (or the app shows under *Pair a device*):

```sh
macon pair --host name.trycloudflare.com --code K7QP-2M9X-4RTD
macon status --host name.trycloudflare.com
```

Pipelines are matched by name, id, or unique prefix — `macon trigger my` works
if only one pipeline starts with "my". Against a headless runner the config is
fixed: `status`/`logs`/`trigger`/`cancel` all work, but add/edit/delete of
pipelines needs the desktop app.

---

## `macon metrics` — Prometheus

Every runner serves **`GET /metrics`** (Prometheus text, same bearer auth):
gauges for pipelines/watching/building, per-pipeline build totals by result,
and last-build duration. `macon metrics` prints it; scrapers authenticate with
the device token:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: macon
    static_configs: [{ targets: ["mac-mini.local:8899"] }]
    authorization: { credentials: "<device token>" }
```

---

## `macon config` — portable config tooling

```sh
macon config init                   # write a starter macon-export.json
macon config validate [path]        # field checks; exit 1 on errors (--json)
macon validate <path>               # routes by extension: .json → export, else macon.yml
```

`validate` catches empty workspace/repo/branch, duplicate webhook ports,
missing provider credentials, and secrets that are in neither the file nor the
env — warnings for the soft stuff, errors (exit 1) for what would break a watch.

---

## `macon completions` — shell completions

```sh
macon completions zsh  > $(brew --prefix)/share/zsh/site-functions/_macon
macon completions bash > $(brew --prefix)/etc/bash_completion.d/macon
```

---

## `macon companion` — iPhone/iPad app

The [MacOn companion app](https://github.com/alimusawa313/MacON_Companion) lets you
**monitor builds and tail logs live** from your phone or iPad. Add `--companion` to
any `watch` to serve it:

```sh
macon watch --workspace acme --repo app --branch main --companion
```

On start it prints a pairing box — an **address** and a one-time **code**:

```
┌─ Pair the MacOn companion app ──────────────────────
│  Address:  alis-mac.local:8899
│  Code:     K7QP-2M9X-4RTD   ·  valid 15 min, one device
└──────────────────────────────────────────────────────
```

In the app: **Add runner** → enter that address + code. It exchanges the code for a
long-lived device token (stored in the iOS Keychain) and reconnects silently after.
The code is **single-use** and expires; brute force is rate-limited.

### Headless / EC2 Macs

There's no screen to read on a remote Mac — the code prints to the log, so grab it
over SSH. Expose the port through a **cloudflared tunnel** and pair the app against
the tunnel host (the app talks HTTPS/WSS):

```sh
cloudflared tunnel --url http://localhost:8899   # → https://<name>.trycloudflare.com
# In the app, use that hostname as the address.
```

### Managing devices

File-based, so it works even with no server running:

```sh
macon companion devices             # list paired iPhones/iPads
macon companion revoke <prefix>     # revoke one by token prefix (from `devices`)
macon companion revoke-all          # revoke every device
```

| `watch` flag | Default | Meaning |
|---|---|---|
| `--companion` | off | serve the companion app |
| `--companion-port N` | `8899` | server port |
| `--pair-ttl MIN` | `15` | pairing-code lifetime |
| `--pair-code CODE` | random | pin a known code (e.g. to pair a second device later) |

> **Screen streaming:** from the **app** (Settings → Companion app → *Let paired
> devices view this screen*), a paired device can also watch the Mac's screen live
> — the app captures with ScreenCaptureKit and hardware-encodes H.264 (VideoToolbox)
> at up to 60–120 fps. A paired device can also **control** the Mac (cursor +
> keyboard) when *Let paired devices control this Mac* is on and Accessibility is
> granted. Both are app features. `macon watch --companion` from the CLI serves
> builds, live logs, and pipeline status — the companion (and `macon status`
> from another machine) can watch/run its pipelines, but the config itself is
> fixed, and a headless runner has no display to capture or drive.

---

## `macon pipelines` — inspect an export

```sh
macon pipelines macon-export.json
```

Lists each pipeline's provider, repo, branch/PR target, and trigger mode.

---

## Authentication

Passed via flags or environment variables (flags win):

| Provider | Needs | Env vars |
|---|---|---|
| **Bitbucket** | email + API token | `BITBUCKET_EMAIL`, `BITBUCKET_API_TOKEN` |
| **GitHub** | Personal Access Token | `GITHUB_TOKEN` |

```sh
export BITBUCKET_EMAIL=you@example.com BITBUCKET_API_TOKEN=…
export GITHUB_TOKEN=ghp_…
```

GitHub PAT needs repo access — classic `repo` scope, or fine-grained with
**Contents + Commit statuses + Pull requests**.

## Secrets for builds

Any secret your `macon.yml`/fastlane needs (e.g. `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_KEY_CONTENT`, `SLACK_URL`) is read from the **inherited shell environment** —
unless you exported the app config *with secrets*, in which case they're baked
into the file.

## Trigger modes

- **Polling** (default) — asks the host every `--every` seconds. Works anywhere;
  up to that lag between commit and build.
- **Webhook** (`--webhook`) — builds the instant the host calls
  `http://<mac>:<port>/`. Needs the Mac reachable (LAN, port-forward, or a tunnel
  like cloudflared). Register that URL in the repo's webhook settings for Push
  (and Pull Request) events.

---

## Common recipes

```sh
# fresh machine → ready to build
brew install alimusawa313/macon/macon && macon init

# watch main on Bitbucket, build each commit
BITBUCKET_EMAIL=you@x.com BITBUCKET_API_TOKEN=… \
  macon watch --workspace academytools --repo planpal-ios-learner-2 --branch main

# watch open PRs on GitHub, instant (webhook)
GITHUB_TOKEN=ghp_… \
  macon watch --provider github --workspace my-org --repo app --prs --webhook --port 8787

# run everything from your app setup, in the background
nohup macon watch --config ~/Desktop/macon-export.json > ~/macon.log 2>&1 &
tail -f ~/macon.log

# one-off release build from a checkout
macon run --workflow beta ~/src/planpal

# watch main AND serve the iPhone/iPad companion app
macon watch --workspace acme --repo app --branch main --companion

# kick a build from anywhere and gate on the result (e.g. inside another CI)
macon trigger "My App" --host runner.example.com --follow

# scriptable status
macon status --json | jq '.builds[0].status'
```

## Exit codes

`macon run` exits with the build's status (`0` = passed, non-zero = failed).
`macon logs --follow` and `macon trigger --follow` exit `0`/`1` by the build's
result. `macon doctor --json` and `macon config validate` exit non-zero when
something's wrong. `watch` runs until interrupted.
