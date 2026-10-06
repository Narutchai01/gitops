# gitops

Reusable GitHub Actions for Next.js and Go release candidates and production releases.

## Composite actions

Call an action from another repository with `uses: narutchai01/gitops/.github/actions/<action>@main`. The caller must check out its own source first. Release actions expect an Ubuntu runner and Bash; production checks also use `git` and `jq`.

| Action | Inputs | Outputs |
| --- | --- | --- |
| `prepare-rc` | Required: `release-branch` | `version`, next `tag` |
| `prepare-production` | Required: `release-branch`, `release-sha`, `main-sha`; optional: `allow-package-version-change` (default `true`) | `version`, `rc-tag`, `final-tag` |
| `node-quality` | Optional: `node-version` (default `24`) | — |
| `go-quality` | Requires `go.mod` at the repository root | — |
| `build-image` | Required: `tags`, `token`; optional: `registry` (default `ghcr.io`), `image-name` (default caller repository) | `digest` |
| `promote-image` | Required: `rc-tag`, `final-tag`, `token`; optional: `registry` (default `ghcr.io`), `image-name` (default caller repository) | `digest` |
| `create-release` | Required: `tag`, `token`; optional: `sha` (default caller commit), `prerelease` (default `false`) | — |

Example steps after checkout:

```yaml
- uses: narutchai01/gitops/.github/actions/node-quality@main
  with:
    node-version: 24
- uses: narutchai01/gitops/.github/actions/build-image@main
  id: image
  with:
    registry: ghcr.io
    image-name: ${{ github.repository }}
    tags: |
      ghcr.io/${{ github.repository }}:latest
      ghcr.io/${{ github.repository }}:sha-${{ github.sha }}
    token: ${{ secrets.GITHUB_TOKEN }}
```

Grant the caller `contents: write` for releases and `packages: write` for image actions. The token is passed explicitly to each action that needs it.

## Reusable workflows

Go projects need a root `go.mod` and `Dockerfile`; the Go RC workflow runs `go vet ./...` and `go test ./...` before building the image:

```yaml
jobs:
  release-rc:
    uses: narutchai01/gitops/.github/workflows/release-rc-go.yml@main
    permissions:
      contents: write
      packages: write
```

Go production releases use the same image promotion flow and require the full source tree to match the tested RC:

```yaml
jobs:
  release:
    uses: narutchai01/gitops/.github/workflows/release-go.yml@main
    with:
      release-branch: release/1.4.0
      release-sha: ${{ needs.merge.outputs.release-sha }}
      main-sha: ${{ needs.merge.outputs.main-sha }}
    permissions:
      contents: write
      packages: write
```

The generic production workflow keeps the Next.js default: it permits only `package.json.version` to change between the RC and main tree. Go production calls it with `allow-package-version-change: false`, which checks the entire tree and does not require `package.json`.

For Next.js RC, use:

```yaml
jobs:
  release-rc:
    uses: narutchai01/gitops/.github/workflows/release-rc-nextjs.yml@main
    permissions:
      contents: write
      packages: write
```

Next.js production callers pass the release branch, its tested head SHA, and the main merge SHA:

```yaml
jobs:
  release:
    uses: narutchai01/gitops/.github/workflows/release-next.yml@main
    with:
      release-branch: release/1.4.0
      release-sha: ${{ needs.merge.outputs.release-sha }}
      main-sha: ${{ needs.merge.outputs.main-sha }}
    permissions:
      contents: write
      packages: write
```

The workflows use the caller repository's source and container image. The caller must provide the matching language project files and Docker build context. References use `@main`, so callers receive the current action definitions when they start a run.

## Check

Run `ruby tests/actions_check.rb` to exercise release versioning, Go quality checks, production validation, tag repeat/conflict behavior, image digest checks, and workflow references. The check uses temporary Git repositories and mock `docker`/`gh` commands; it does not publish a release or image. It requires Ruby, Git, and Go.
