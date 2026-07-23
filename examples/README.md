# Examples

Ready-to-adapt consumer files for this module: the Hiera `data/` layer every consumer needs,
plus the skeleton that completes a standalone control repository.

## Fleet adoption

On hosts managed by a Puppet server (or any control-repository/r10k setup), no skeleton is
needed: add the module and its dependencies to the control repository's `Puppetfile`, declare
the class from a role or profile (`include rootless_gitlab_runner`), and supply the same
`data/` through the server's Hiera.

- **`data/`** — the runner configuration as plain class parameters: `common.yaml` (shared
  defaults) and `nodes/host.example.yaml` (per-host). Copy the node file to
  `nodes/<hostname>.yaml` and adjust; the `standalone` block is marked and dropped on a
  fleet host.
- Runner tokens ride the server-side secrets machinery as
  `rootless_gitlab_runner::runner_tokens`; `secrets.example.yaml` shows the key shape (see
  the README [Secrets](../README.md#secrets) section).

## The standalone skeleton

`Puppetfile`, `hiera.yaml`, and `site.pp` complete a masterless control repository for a
standalone host. Assemble them on the host — `Puppetfile` at the repository root;
`hiera.yaml`, `site.pp` (as `puppet/manifests/site.pp`), and `data/` under `puppet/`:

```
<repository>/Puppetfile
<repository>/puppet/hiera.yaml
<repository>/puppet/manifests/site.pp
<repository>/puppet/data/
```

`hiera.yaml` keeps `data/` beside it (`datadir: data`), so it resolves unchanged in either
place. On a standalone host, `secrets.example.yaml` becomes the off-repository token store at
`/etc/gitlab-runner-infra/secrets.yaml` (root-owned, `0600`), never committed. The standalone
runbook, [`docs/standalone.md`](../docs/standalone.md), walks the bring-up end to end.

## CI for the control repository

- **`gitlab-ci.example.yml`** — a minimal GitLab CI pipeline for the assembled control
  repository: parser validation, YAML lint, and the module's Hiera data-versus-surface check
  (see the README [Validating Hiera data in CI](../README.md#validating-hiera-data-in-ci)). Copy
  it to `.gitlab-ci.yml` at the repository root; the paths match the skeleton layout above.
