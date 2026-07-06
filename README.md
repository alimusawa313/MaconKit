# MaconKit + `macon`

Shared core for MacON, plus a terminal front-end (`macon`). The SwiftUI app and
the CLI both build on `MaconKit`, so a pipeline runs identically in either.

## The CLI

```
macon version
macon lint [path]                 # parse & summarize a macon.yml
macon run [--workflow N] [--branch B] [--file macon.yml] [path]
```

`macon run` executes a `macon.yml` workflow in a repo directory (the current
checkout) and streams output, exiting non-zero on failure — so it drops into a
git hook, cron, or another CI. Secrets are read from the inherited shell env:

```sh
ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_CONTENT=… macon run --workflow beta
```

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
