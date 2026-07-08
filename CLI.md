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
macon init [--check]              check the iOS toolchain; install missing tools
macon lint [path]                 parse & summarize a macon.yml
macon pipelines [file.json]       list pipelines in an app export file
macon run [options] [path]        run one workflow once, here
macon watch [options]             watch a repo and build new commits (until Ctrl-C)
macon watch --config file.json    watch pipelines exported from the app
macon service <install|…>         run a watch as a launchd service
macon help                        show usage
```

---

## `macon init` — toolchain doctor

Check that everything an iOS build needs is present; auto-install the
Homebrew-managed ones.

```sh
macon init            # check + install missing (fastlane, SwiftLint, gitleaks, JDK, cloudflared)
macon init --check    # report only, install nothing
```

Checks: Homebrew · Xcode + Command Line Tools · git · Ruby/Bundler · fastlane ·
SwiftLint · gitleaks · JDK · iOS simulators · cloudflared. Xcode/simulators print
the command to run (they can't be brew-installed).

---

## `macon lint` — inspect a pipeline file

```sh
macon lint                    # lints ./macon.yml
macon lint path/to/macon.yml
```

Prints the workflows, their steps, `before_run` chains, and triggers. Good for
catching YAML mistakes before a build.

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
```

## Exit codes

`macon run` exits with the build's status (`0` = passed, non-zero = failed), so
it composes with other tools. `watch` runs until interrupted.
