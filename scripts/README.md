# Build / release scripts

## `build.sh`

Reads the version from `AudioMuseAI/install.xml` (single source of truth)
and produces `AudioMuseAI-v<version>.zip` at the repo root. Old versioned
zips are deleted first to keep the dir tidy.

```bash
# Build the zip only
scripts/build.sh

# Build AND rewrite extensions.xml (version, URL, sha)
scripts/build.sh --update-manifest
```

The zip filename is derived from `install.xml`, so to cut a release:

1. Bump `<version>` in `AudioMuseAI/install.xml`.
2. Bump the matching `VERSION` constant in `AudioMuseAI/Plugin.pm`.
3. `bash tests/run-all.sh` (must be green).
4. `scripts/build.sh --update-manifest`.
5. Commit, tag, push, `gh release create`.

The script prints the exact commands for steps 5+ on success.

## Why python3 for the zip?

`zip(1)` isn't installed on every dev host (it isn't on this one). The
embedded python snippet is portable, deterministic, and explicitly
strips `.git`, `.DS_Store`, and dotfiles so they never leak into the
release artefact.
