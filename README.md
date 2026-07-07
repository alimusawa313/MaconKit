# MaconKit + `macon`

Shared core for MacON, plus a terminal front-end (`macon`). The SwiftUI app and
the CLI both build on `MaconKit`, so a pipeline runs identically in either.

## The CLI

```
macon version
macon lint [path]                 # parse & summarize a macon.yml
macon run [--workflow N] [--branch B] [--file macon.yml] [path]
macon watch --workspace WS --repo SLUG [--branch B | --prs] [options]
```

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

There are two trigger modes — same as the app:

```sh
export BITBUCKET_EMAIL=you@example.com BITBUCKET_API_TOKEN=…

# Polling (default): ask Bitbucket every 30s, build new commits on main.
macon watch --workspace academytools --repo planpal-ios-learner-2 --branch main

# Polling, open PRs targeting main instead of a branch.
macon watch --workspace academytools --repo planpal-ios-learner-2 --prs --pr-target main

# Webhook (push): build the instant Bitbucket calls us — no lag, no idle polling.
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
