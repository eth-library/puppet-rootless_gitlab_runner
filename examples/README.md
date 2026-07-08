# Examples

A ready-to-adapt standalone (masterless `puppet apply`) consumer of this module. On a host
managed by a central Puppet server, no skeleton is needed — declare the class from a role or
profile like any other module and supply the same `data/` through the server's Hiera; see the
main [README](../README.md) and [`REFERENCE.md`](../REFERENCE.md) for the parameter surface.

## The config

- **`data/`** — the runner configuration as plain class parameters: `common.yaml` (shared
  defaults) and `nodes/host.example.yaml` (per-host). Copy the node file to
  `nodes/<hostname>.yaml` and adjust.
- **`secrets.example.yaml`** — the off-repo token store. It belongs at
  `/etc/gitlab-runner-infra/secrets.yaml` on the host (root-owned, `0600`), never in the
  control repo. See the README [Secrets](../README.md#secrets) section.

## The standalone skeleton

`Puppetfile`, `hiera.yaml`, and `site.pp` complete a masterless control repo. Assemble them
on the host — `Puppetfile` at the repo root; `hiera.yaml`, `site.pp` (as
`puppet/manifests/site.pp`), and `data/` under `puppet/`:

```
<repo>/Puppetfile
<repo>/puppet/hiera.yaml
<repo>/puppet/manifests/site.pp
<repo>/puppet/data/
```

`hiera.yaml` keeps `data/` beside it (`datadir: data`), so it resolves unchanged in either
place. The README [Installation](../README.md#installation) section walks the bring-up end to
end.
