# MaconKit + `macon`

Shared core for MacON, plus a terminal front-end (`macon`). The SwiftUI app and
the CLI both build on `MaconKit`, so a pipeline runs identically in either.

## The CLI

```
macon version
macon doctor | init [--check]     # check toolchain, permissions, cloudflared, disk
macon lint [path]                 # parse & summarize a macon.yml
macon run [--workflow N] [--branch B] [--file macon.yml] [path]
macon watch --workspace WS --repo SLUG [--branch B | --prs] [options]
macon status | logs | trigger | cancel | metrics    # remote-control a running runner
macon config <init|validate>      # scaffold / check the portable config
macon install-service […]         # run a watch as a launchd service
macon completions <zsh|bash>      # shell completions
```

See **[CLI.md](CLI.md)** for the full command reference (every flag, auth, trigger
modes, and recipes).

`macon run` executes a `macon.yml` workflow in a repo directory (the current
checkout) and streams output, exiting non-zero on failure — so it drops into a
git hook, cron, or another CI. Secrets are read from the inherited shell env:

```sh
ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_CONTENT=… macon run --workflow beta
```

`macon watch` is the headless equivalent of the app's **Start Watching**: it
learns about new commits (or open PRs), clones/checks out each one, runs the
matching `macon.yml` workflow, and posts build status back. It runs until Ctrl-C
— ideal under `tmux`, `nohup`, or a `launchd` job. Auth comes from `--email` /
`--token` or the `BITBUCKET_EMAIL` / `BITBUCKET_API_TOKEN` env vars; secrets are
inherited from the shell env, same as `run`.

It works with **Bitbucket** or **GitHub** (`--provider`, default `bitbucket`).
For GitHub, `--workspace` is the owner/org and auth is a PAT via `--token` or
`GITHUB_TOKEN`:

```sh
# --- Bitbucket ---
export BITBUCKET_EMAIL=you@example.com BITBUCKET_API_TOKEN=…
macon watch --workspace academytools --repo planpal-ios-learner-2 --branch main

# --- GitHub ---
export GITHUB_TOKEN=ghp_…
macon watch --provider github --workspace my-org --repo my-app --branch main
```

There are two trigger modes — same as the app:

```sh
# Polling (default): ask the host every 30s, build new commits on main.
macon watch --workspace academytools --repo planpal-ios-learner-2 --branch main

# Polling, open PRs targeting main instead of a branch.
macon watch --workspace academytools --repo planpal-ios-learner-2 --prs --pr-target main

# Webhook (push): build the instant the host calls us — no lag, no idle polling.
macon watch --workspace academytools --repo planpal-ios-learner-2 --branch main \
            --webhook --port 8787
```

**Polling** works anywhere (only needs outbound HTTPS) but lags up to the poll
interval. **Webhook** is instant but the Mac must be reachable at the URL you
register in Bitbucket (**repo Settings → Webhooks** → `http://<mac>:8787/`, Push
and/or Pull Request events) — same LAN, a port-forward, or a tunnel like
`cloudflared`/`ngrok`. macOS may prompt once to allow incoming connections.

Run `macon help` for the full option list (`--dir`, `--every`, `--workflow`,
`--file`, `--no-status`).

### Bring your app setup to the terminal

Set everything up in the app, then **Settings → Export Configuration…** writes a
`macon-export.json`. Run all of it headless — no flags to retype:

```sh
macon pipelines macon-export.json          # see what's inside
macon watch --config macon-export.json     # watch them all
macon watch --config macon-export.json --pipeline "PlanPal iOS"   # just one
```

Export **without** secrets (default) for a config-only file — provide token/secret
values via the shell env when you run (`BITBUCKET_API_TOKEN`, `GITHUB_TOKEN`, plus
your own like `SLACK_URL`). Export **with** secrets for a self-contained file
(contains tokens in plain text — keep it private). The app's **Import…** button
loads a file back, so it doubles as a way to move a setup between machines.

### Monitor from your phone: `--companion`

Add `--companion` to any `watch` to serve the **[MacOn companion app](https://github.com/alimusawa313/MacON_Companion)**
(iPhone/iPad) — watch builds and tail logs live:

```sh
macon watch --workspace acme --repo app --branch main --companion
```

It prints a pairing **address + one-time code**; enter them in the app's *Add
runner* screen to get a device token (stored in the iOS Keychain). The code is
single-use and expires. On a headless/EC2 Mac, read the code over SSH and expose
the port via a `cloudflared` tunnel — the app speaks HTTPS/WSS. Manage devices with
`macon companion devices | revoke <prefix> | revoke-all`. Full details in
**[CLI.md](CLI.md#macon-companion--iphoneipad-app)**.

The headless CLI serves **builds + live logs** only. The **MacOn desktop app**'s
companion server adds live **screen streaming** (hardware H.264), **remote
control** (cursor, keyboard, a virtual trackpad, and Mac gestures), a **privacy
screen** for the Mac while you drive it remotely, and **one-tap remote access**
(it opens the `cloudflared` tunnel for you) — see the app's Settings → Companion app.

## First run: `macon init`

Before watching anything, check the machine has what an iOS build needs:

```sh
macon init            # check + auto-install missing Homebrew tools
macon init --check    # report only, install nothing
```

It verifies Homebrew, Xcode + Command Line Tools, git, Ruby/Bundler, fastlane,
SwiftLint, gitleaks, a JDK (for the Bitbucket runner), iOS simulator runtimes,
and cloudflared (optional, for webhook tunnels). Tools available via Homebrew are
installed automatically; Xcode and simulators print the exact command to run.

## Install now (no Homebrew)

```sh
make install                 # → /usr/local/bin/macon
make install PREFIX=~/.local # or a user prefix on your PATH
```

## Install via Homebrew

The app and this kit live in **one repo** (monorepo); `MaconKit` is a subpackage.
The build-from-source formula in [`Formula/macon.rb`](Formula/macon.rb) builds it
with `--package-path MaconKit`, so publish the **whole repo** as-is.

Bleeding edge (no release needed):
```sh
brew tap YOURNAME/macon https://github.com/YOURNAME/homebrew-macon
brew install --HEAD macon
```

### Publishing stable releases (automated)
Releasing is one command — the release workflow (`.github/workflows/release.yml`
at the repo root) verifies the build and updates the tap formula on every tag:
```sh
git tag v0.1.0 && git push --tags
```
One-time setup: create an empty `homebrew-macon` tap repo, and add a PAT
(`contents:write` on the tap) as the repo secret `HOMEBREW_TAP_TOKEN`. Then users:
```sh
brew tap YOURNAME/macon https://github.com/YOURNAME/homebrew-macon
brew install macon
```

The formula compiles from source, so no code signing or notarization is needed.

> If you ever want a standalone CLI repo, move `MaconKit/` to its own repo root and
> drop the `--package-path MaconKit` bits — the package is already self-contained.
