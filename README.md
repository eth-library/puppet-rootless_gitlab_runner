# Puppet-managed Rootless GitLab Runner

[![CI](https://github.com/eth-library/puppet-rootless_gitlab_runner/actions/workflows/ci.yml/badge.svg)](https://github.com/eth-library/puppet-rootless_gitlab_runner/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![Release](https://img.shields.io/github/v/release/eth-library/puppet-rootless_gitlab_runner)](https://github.com/eth-library/puppet-rootless_gitlab_runner/releases)
![Puppet: >= 8 < 9](https://img.shields.io/badge/puppet-%3E%3D%208%20%3C%209-blue)
![Ubuntu: 22.04](https://img.shields.io/badge/ubuntu-22.04-blue)

> [!NOTE]
> This module is maintained on a best-effort basis and provided as is, without
> warranty of any kind; review every change and apply it at your own risk.

`rootless_gitlab_runner` is a Puppet module that installs and manages a **rootless
GitLab Runner** [\[5\]](#ref-5), together with the rootless-Docker [\[4\]](#ref-4)
daemon it depends on.

## Table of contents

- [Why this module](#why-this-module)
- [Quick start](#quick-start)
- [Operating model](#operating-model)
- [Prerequisites](#prerequisites)
  - [Host requirements](#host-requirements)
- [Configuration contract](#configuration-contract)
  - [Managed concerns](#managed-concerns)
  - [Opt-in concerns](#opt-in-concerns)
  - [Host-specific values](#host-specific-values)
  - [File layout](#file-layout)
  - [Declaring runners](#declaring-runners)
  - [Validating Hiera data in CI](#validating-hiera-data-in-ci)
- [Security](#security)
  - [Why rootless](#why-rootless)
  - [What the module locks down](#what-the-module-locks-down)
  - [Keeping the daemon socket out of jobs](#keeping-the-daemon-socket-out-of-jobs)
- [Secrets](#secrets)
  - [Why use a secret file over environment variables](#why-use-a-secret-file-over-environment-variables)
  - [The secret file](#the-secret-file)
  - [Editing the secret store](#editing-the-secret-store)
- [Installation](#installation)
- [Applying the configuration](#applying-the-configuration)
  - [Restarts and graceful shutdown](#restarts-and-graceful-shutdown)
  - [Automating with systemd](#automating-with-systemd)
  - [Self-update prerequisites](#self-update-prerequisites)
  - [Rolling back a commit](#rolling-back-a-commit)
  - [Verifying the host](#verifying-the-host)
- [Lifecycle operations](#lifecycle-operations)
  - [Adding a runner](#adding-a-runner)
  - [Rotating a token](#rotating-a-token)
  - [Removing a runner](#removing-a-runner)
  - [Retiring the host](#retiring-the-host)
- [Contributing](#contributing)
- [Roadmap](#roadmap)
- [License](#license)
- [References](#references)

## Why this module

A rootless GitLab Runner has several moving parts that are easy to drift or break on an
unmanaged host: the runner config, a rootless-Docker systemd drop-in that the daemon depends on,
and the host packages. This repository captures that state as code so it
is reviewable, reproducible and self-healing. Each change is reviewed before it reaches a host,
instead of being applied by hand on the server.

Setting a rootless runner up by hand is fiddly, slow, and easy to get subtly wrong. A forgotten
step is often a *security* gap: a rootful daemon left running, a missing socket restriction.
Capturing the host as declarative, tested Puppet code makes that posture something the host
*enforces*: every apply re-asserts it and re-converges the drift that background patching
introduces, and encoding it once pays back on every additional host.

Everything host- or team-specific is supplied as Hiera data [\[2\]](#ref-2) from a **separate
repository that consumes this module** — a per-site *control repository* that pins the module and
holds its data; the module itself is never edited to consume it. It supports two consumption paths:

- **Part of an orchestrated fleet**, for hosts already managed by a Puppet server (or any
  control-repository/r10k setup): declare the class from a role or profile like any other module —
  `include rootless_gitlab_runner`. The `include` is only the wiring; a fleet
  host still needs the **same configuration as standalone**: the Hiera data
  ([Configuration contract](#configuration-contract)) and the secret store
  ([Secrets](#secrets)), supplied from your own control repository. The files under
  [`examples/data/`](examples/data/) work there verbatim; the
  parameter defaults are server-safe.
- **Standalone**, for hosts that cannot be enrolled in central configuration management:
  `puppet apply` [\[1\]](#ref-1) runs directly on the host from a control-repository checkout deployed
  with r10k [\[8\]](#ref-8); optionally the module installs a systemd timer that keeps the host
  converging on the repository's protected `main` branch, with every change still review-gated
  through git.

The [Installation](#installation) section documents the standalone path end to end; a fleet
consumer adds the Puppetfile entry and provides the same Hiera data and secret store through
their control repository and server-side machinery.

No established Puppet module appears to manage a rootless GitLab Runner host end to end. The
existing
[`voxpupuli/puppet-gitlab_ci_runner`](https://github.com/voxpupuli/puppet-gitlab_ci_runner) has no
rootless path, so the entire stack would have to be built on top; that stack is exactly what this
module packages. It is the opinionated rootless-first alternative, with an optional signed
self-update loop: a host tracks its own signed control-repository branch and re-applies on a timer,
so a single machine stays converged on its own. That makes it an easy on-ramp for a one-off host
with no full r10k/Puppet-server fleet behind it.

## Quick start

The fastest path to a working runner: a fresh Ubuntu 22.04 host that the module takes from a bare
OS to a fully configured one. Each step is detailed in [Installation](#installation).

1. Install OpenVox 8, git and r10k on the host.
2. Copy [`examples/`](examples/) into a new control repository, pin this module's `:commit` in
   the `Puppetfile`, clone it to the host, and fetch its modules with r10k.
3. Create the off-repository secret store and add the runner's `glrt-` token
   ([Editing the secret store](#editing-the-secret-store)).
4. Rename the example node file to `puppet/data/nodes/<hostname>.yaml` and set `runner_uid` and
   the runner's `token_key`.
5. Dry-run, then apply.

Once the apply succeeds, the runner connects to GitLab; see
[Verifying the host](#verifying-the-host).

## Operating model

> [!TIP]
> **Use a dedicated host for the GitLab Runner.** Its only job should be running the runners,
> ideally on a disposable, rebuildable VM. To harden the runner the module takes over
> host-level state: with `manage_rootless_docker` on it masks the host's rootful Docker and containerd daemons, and
> it manages the runner user and its rootless daemon. That is safe on a single-purpose host but would
> disrupt other workloads, so it is not intended for a server that also runs other applications or
> services. Dedicating a host to the runner is the common, best-practice approach and the cleaner
> isolation boundary.

- The module `rootless_gitlab_runner` holds the **generic logic** and is never edited to onboard
  a host or team; every host is driven by its own **control repository** (the separate repository
  above).
- All per-host and per-team values live in **Hiera data**; secrets live in an off-repository store on
  the host.
- `puppet apply` runs with an **isolated `--confdir`/`--vardir`**, so it never collides with any
  central Puppet agent that may also manage the host.
- Puppet is **idempotent**: every run converges the host to the declared state, which means
  re-running is also the drift-correction mechanism.
- **Standalone only:** a systemd timer [\[6\]](#ref-6) can automate those runs (see
  [Applying the configuration](#applying-the-configuration)); in a fleet, your Puppet server's
  agent already provides that continuous convergence.

## Prerequisites

The module targets **Ubuntu 22.04** with **Puppet/OpenVox 8** [\[3\]](#ref-3) (see `metadata.json`
for the exact supported version range). Before an apply does anything useful, the host needs:

- **Puppet (or OpenVox) 8** installed and `puppet` on `PATH`.
- The **`gitlab-runner` system user and home**, plus its **rootless-Docker** user daemon,
  unless the module manages them: with `manage_runner_user` off the user is an external
  prerequisite (owned elsewhere, for example by a central Puppet), and with
  `manage_rootless_docker` off the daemon and its host requirements are.

What the module owns on a host is configuration too; the ownership toggles and their parameters
live in the [Configuration contract](#configuration-contract).

### Host requirements

A rootless GitLab Runner host needs the following in place. With `manage_runner_user` and
`manage_rootless_docker` on, the module establishes and keeps converging them (apt packages by
listing them in `packages`); with the toggles off they are external prerequisites the host must
provide, and the preflight is not enforced — so a missing prerequisite on the toggle-off path
surfaces as a raw Puppet or host error rather than the module's clear preflight message. On Ubuntu
22.04 these are the current, verified requirements:

- **Subordinate IDs:** `/etc/subuid` and `/etc/subgid` [\[12\]](#ref-12) must each grant the runner
  user at least **65,536** IDs (for example `gitlab-runner:231072:65536`). A plain
  `useradd --system` does not reliably allocate these.
- **`uidmap` package:** Provides `newuidmap` and `newgidmap` [\[13\]](#ref-13), required for
  user-namespace mapping. It is not always pulled in automatically.
- **`dbus-user-session` package:** Lets `systemctl --user` work under lingering. [\[4\]](#ref-4)
- **Lingering:** `loginctl enable-linger` [\[14\]](#ref-14) for the runner user, so its systemd user
  manager and `XDG_RUNTIME_DIR=/run/user/<uid>` [\[19\]](#ref-19) exist at boot without an
  interactive login.
- **cgroup v2:** [\[15\]](#ref-15) The unified hierarchy, the default on 22.04, is required for the
  rootless daemon and for container resource limits.
- **Storage driver:** The `overlay2` driver [\[16\]](#ref-16) works rootless on kernel **5.11** or
  newer (jammy ships 5.15). On older kernels the fallback is `fuse-overlayfs` [\[17\]](#ref-17)
  (kernel 4.18 or newer, plus the `fuse-overlayfs` package).
- **Daemon connection (`DOCKER_HOST`):** [\[18\]](#ref-18) Required for every rootless job: it is how the runner
  manager reaches the rootless daemon to create job containers. Set
  `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` in the runner service environment, equivalently
  the `host` setting under `[runners.docker]`. This is distinct from bind-mounting the socket into a
  job (`socket_mount`), which only jobs that drive Docker themselves need (for example
  `docker buildx`, whose default driver also builds through the daemon), not the runner to start
  containers.

#### Limitations

Edge cases the module deliberately does not manage (host-side concerns, kept out of scope so the
module never writes system-wide configuration):

- **Container CPU/cpuset/IO limits are silently unenforced** (only `memory` and `pids` are
  delegated to the runner user by default). Jobs that need them require cgroup v2 delegation via
  a host-side drop-in in `/etc/systemd/system/user@.service.d/`.
- `ping` inside containers needs the `net.ipv4.ping_group_range` sysctl; binding ports below
  1024 needs a sysctl or capability grant. Build jobs rarely need either.
- **Package versions are neither pinned nor held** — `packages` uses `ensure => installed`. This
  is deliberate: the module exists to make routine upgrades *safe* (the `no-detach-netns` fix
  survives them), not to freeze them, so per-apply convergence — not a version lock — is the
  defense against a bad upgrade. Pin or hold at the apt layer where a specific host needs it.

## Configuration contract

Runner configuration is data in Hiera, kept in your control repository, not in GitLab CI/CD
variables. A timer-driven `puppet apply` never sees CI/CD variables, the runner's own token cannot
live where the runner must already be running, and Hiera-in-git is auditable. The module is
**never edited to onboard a host or team**: you add a Hiera data layer, and the host's secret
store, instead.

### Managed concerns

The **runner config** (`config.toml`) is always managed, with no toggle: on every apply the module
renders it from the Hiera data, the module's baseline output.

The module also always applies the **no-detach-netns drop-in**, a small systemd override that pins
`DETACH_NETNS=false` [\[22\]](#ref-22) (NETNS stands for network namespace [\[27\]](#ref-27)). It fixes the recurring Ubuntu 22.04 breakage where a
rootless-Docker package upgrade silently breaks container networking (it is specific to that
platform, not a universal setting).

The substantial host bring-up (the rootless-Docker daemon, the runner user, the service) is opt-in
below.

### Opt-in concerns

Each remaining concern is a Hiera toggle, opt-in by default:

| Concern | Hiera parameter | Default |
|---|---|---|
| apt packages | [`rootless_gitlab_runner::packages`](#packages) | `[]` |
| apt repositories serving those packages | [`rootless_gitlab_runner::manage_apt_repos`](#manage_apt_repos) | `false` |
| Runner user, home | [`rootless_gitlab_runner::manage_runner_user`](#manage_runner_user) | `false` |
| Rootless-Docker daemon bring-up, subordinate IDs | [`rootless_gitlab_runner::manage_rootless_docker`](#manage_rootless_docker) | `false` |
| Runner service + its systemd drop-in | [`rootless_gitlab_runner::manage_runner_service`](#manage_runner_service) | `false` |
| Standalone self-update loop + healthcheck | [`rootless_gitlab_runner::manage_standalone_self_update`](#manage_standalone_self_update) | `false` |

#### `packages`

The apt packages to ensure installed; the default empty list installs nothing. A rootless-runner
host on Ubuntu 22.04 needs the user-namespace helper `uidmap` [\[13\]](#ref-13) and
`dbus-user-session` [\[29\]](#ref-29); the Docker Engine package `docker-ce` [\[30\]](#ref-30), its
CLI `docker-ce-cli` [\[31\]](#ref-31) and the rootless extras `docker-ce-rootless-extras` (rootless
mode [\[4\]](#ref-4)); `containerd.io`, which packages the containerd runtime [\[32\]](#ref-32);
and `gitlab-runner` [\[5\]](#ref-5). The standalone
[example host data](examples/data/nodes/host.example.yaml) lists the full set. Their apt source is
managed by [`manage_apt_repos`](#manage_apt_repos) or provided externally.

The `manage_*` parameters are **persistent ownership switches**, not one-shot bootstrap flags:
set once in the host's Hiera and left on, so every apply keeps owning and drift-correcting that
concern. `false` means hands-off, not ensure-off.

#### `manage_apt_repos`

Adds the Docker and GitLab Runner apt repositories (with their signing
keys) via `puppetlabs/apt`, so the `packages` list installs on stock Ubuntu. Keep it off where
apt sources are owned elsewhere. `puppetlabs/apt` is needed only by this toggle;
`puppetlabs/stdlib` is needed unconditionally. Consumers add both to their Puppetfile (r10k
does not resolve module metadata dependencies; the example skeleton carries the lines).

#### `manage_runner_user`

Owns the runner group, user, and home. Keep it off
where another configuration-management system owns the user; two owners would fight over it.
The subordinate UID/GID ranges rootless Docker needs are owned by
[`manage_rootless_docker`](#manage_rootless_docker), not this toggle.
Home internals (`.ssh`, `.config`) are never managed, beyond the no-detach-netns drop-in the
module places under `~/.config/systemd/user/`.

#### `manage_rootless_docker`

Brings up the rootless-Docker user daemon: provisions the subordinate UID/GID ranges the
daemon needs (`subid_start`/`subid_count`, default `231072`/`65536`; an existing entry is
never overwritten), enables lingering and runs
`dockerd-rootless-setuptool.sh install` [\[4\]](#ref-4) as the runner user (guarded on installed state, so it
runs only until the rootless daemon's user unit exists). The ranges are provisioned for the
runner user whether the module owns the account ([`manage_runner_user`](#manage_runner_user))
or another system does. The setuptool is upstream's
supported installer and ships in `docker-ce-rootless-extras`, version-locked to the daemon
it configures — the module invokes it rather than re-rendering its output, so the generated
user unit (`~/.config/systemd/user/docker.service`) can never drift out of step with the
installed Docker. That unit remains upstream's artifact; the module's sole modification to
it is the `no-detach-netns` drop-in, layered on top as a systemd override so both survive
the other changing.

The whole chain sits behind a fail-loud preflight that asserts the prerequisites (`newuidmap` present,
subordinate IDs of at least 65,536, lingering enabled, cgroup v2) and aborts with a clear
message — only active when `manage_rootless_docker` is `true`. On a host where everything is already in place the
chain is a no-op.

The toggle also **stops and masks the rootful system
`docker.service`/`docker.socket` and the idle root `containerd.service`** (which installing
`docker-ce`/`containerd.io` starts as root), so the only container daemon on the host is the
unprivileged one — see [Security](#security).

#### `manage_runner_service`

With `manage_runner_service` on, the module owns the `gitlab-runner` system service, a
systemd drop-in for it (`/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf`), and
the mode on `/etc/gitlab-runner` so the privilege-dropped manager can read its own config. By
default the drop-in runs the manager privilege-dropped as the runner user, with `DOCKER_HOST`
pointed at the rootless docker socket. The posture is data, not a separate toggle:
`rootless_gitlab_runner::service_user` (set `'root'` to keep the packaged root-running unit) and
`rootless_gitlab_runner::service_environment` (the environment lines rendered into the drop-in).

#### `manage_standalone_self_update`

Installs the self-update loop, two units each on its own timer:

- An apply script (`/usr/local/sbin/rootless-gitlab-runner-apply`), a oneshot systemd service +
  timer (default every `5min`) that fetch the control-repository checkout (`repo_path`), run
  `git verify-commit` on the remote branch (only signed commits are applied), reset to it, install
  Puppetfile-pinned modules via `r10k puppetfile install` (a no-op without a Puppetfile), and
  re-apply.
- A healthcheck script + timer (default every `15min`) that verifies the manager service, the
  rootless daemon (`docker info` as the runner user, from a non-login context), and that the
  checkout is not stale against the remote (a dead pull credential fails loud instead of leaving
  the host applying old code behind a green timer).

The service sets `HOME=/root` (git/SSH need it) and an explicit `TimeoutStartSec`; Puppet exit
code 2 ("changes applied") counts as success.

Never enable it where a Puppet server or r10k already deploys the host: one deploy agent per host.

### Host-specific values

Beyond the toggles, two contract values are **host data** — set per host in the Hiera node
file ([`host.example.yaml`](examples/data/nodes/host.example.yaml) shows both). `runner_uid`
has no default and the apply **fails at compile time with a clear message** when it is unset
but needed; `repo_path` is defaulted but host-specific:

| Parameter | Description | Default |
|---|---|---|
| `runner_uid` | Numeric uid of the runner user; the rootless runtime paths (`/run/user/<uid>`, the docker socket) derive from it | none — required when `manage_runner_user`, `manage_rootless_docker` or `manage_standalone_self_update` is on, or for a `socket_mount` runner without `docker_socket_path` |
| `repo_path` | Checkout of the control repository on the host (the self-update target) | `/opt/gitlab-runner-infra` |

A wrong `repo_path` is caught at runtime — by the self-update service's fetch and the
healthcheck's staleness assertion — not at compile time.

### File layout

Non-secret configuration (concurrency, the runners list, images, URLs,
paths) is Hiera data in your control repository; runner **tokens** are kept out of that repository, in a
host-local secret store (`/etc/gitlab-runner-infra/secrets.yaml`, `0600`; see
[Secrets](#secrets)). The control repository's `hiera.yaml` ties them together:

```
Off-repository secret store (tokens)   ->  /etc/gitlab-runner-infra/secrets.yaml
Per-node                               ->  puppet/data/nodes/<hostname>.yaml
Common defaults                        ->  puppet/data/common.yaml
```

### Declaring runners

You list runners under `rootless_gitlab_runner::runners` in your host's node
data file (`puppet/data/nodes/<hostname>.yaml`; copy
[`host.example.yaml`](examples/data/nodes/host.example.yaml) to start). On every
apply the module renders that list into the runner's config file, `/etc/gitlab-runner/config.toml`.
That is the one file the module owns and rewrites; you never edit it by hand. One host can run
several runners from that single file, and values shared by every runner (`url`, `image`,
`executor`, …) can live once in `rootless_gitlab_runner::runner_defaults`, a hash merged under
every entry where per-entry keys win. The shipped example additionally hoists
`url`/`executor`/`image` into `runner_defaults`; see
[`host.example.yaml`](examples/data/nodes/host.example.yaml) and
[`common.yaml`](examples/data/common.yaml) for the complete files. A minimal,
self-contained entry:

```yaml
rootless_gitlab_runner::runners:
  - name: docker-rootless
    url: https://gitlab.example.org/
    executor: docker
    image: ubuntu:22.04
    token_key: runner_a      # resolves the glrt- token from the secret store
```

The module renders a **curated subset** of `config.toml` runner options — the common
Docker-executor keys — rather than GitLab Runner's full surface. An unrecognized runner key
**fails the apply**: a mistyped key is usually a typo, and silently dropping it could quietly
disable a control such as `allowed_images`, so the supported set is explicit by design. The
recognised runner keys are enumerated under
[`runners` in REFERENCE.md](REFERENCE.md#-rootless_gitlab_runner--runners). If an
option is needed that the module does not yet render, please open an issue — see
[Contributing](#contributing).

Because the whole `config.toml` is re-rendered from the list each apply,
deleting an entry from the data removes it from the host on the next run: no per-runner
`ensure => absent`, no unregistration machinery. The GitLab-side runner record is the one thing
this does not touch; delete it there too ([Removing a runner](#removing-a-runner)).

> `socket_mount: true` bind-mounts the daemon socket into a runner's jobs, giving them control of
> the daemon as the runner user (they can start containers and read the runner token). Keep it off
> unless a job must drive Docker, and constrain it with `allowed_images` [\[23\]](#ref-23) when it is on. See
> [Keeping the daemon socket out of jobs](#keeping-the-daemon-socket-out-of-jobs).

The complete parameter reference, generated from the code's own documentation, is in
[REFERENCE.md](REFERENCE.md).

### Validating Hiera data in CI

Hiera's automatic parameter lookup resolves only the parameters a class declares. Any other
`class::param` key in the control repository's data — a typo, or a key left over from an older
module version — is **silently ignored**: the catalog compiles, the apply succeeds, and the
intended configuration never lands. Nothing in Puppet or PDK catches this for a standalone
`puppet apply` topology.

The module therefore ships a data-versus-surface check,
[`scripts/check_hiera_data.rb`](scripts/check_hiera_data.rb): it reads the declared parameter
surface of the deployed modules (via `puppet strings`, the tool behind
[REFERENCE.md](REFERENCE.md)) and fails, listing every offender, when a key in the data
directory names a class absent from the deployed modules or a parameter no class declares.
Run it in the control repository's CI after `r10k puppetfile install`, so every merge request
that touches data is gated:

```
ruby puppet/modules/rootless_gitlab_runner/scripts/check_hiera_data.rb --data-dir puppet/data --hiera-config puppet/hiera.yaml --modulepath puppet/modules
```

[`examples/gitlab-ci.example.yml`](examples/gitlab-ci.example.yml) is a minimal copy-paste
pipeline (parser validation, YAML lint, this check) for a standalone control repository; the
same command also works as a pre-commit hook for local feedback. Two behaviors to know:

- **Advisory, non-failing:** subkeys set under a hash parameter whose effective `manage`
  toggle resolves to `false` are recognized but inert (the module is hands-off that concern).
  The check reports them as an advisory rather than a failure — declaring the state of an
  externally owned concern can be intentional — and a human judges intent.
- **Stated limits:** the check validates key names, not values (types are the compiler's job,
  enforced at compile time), and it cannot see data layers outside the repository, such as the
  off-repository secret store. Hierarchy levels addressed by `glob`/`globs` or `mapped_paths`
  are not modeled; advisory resolution covers `path`/`paths` levels only.

The module's own [`examples/data/`](examples/data/) is held to the same rule by the unit
suite, so the shipped examples cannot drift from the parameter surface.

## Security

### Why rootless

A conventional Docker daemon runs as root, so anything that can reach its
socket controls the daemon, and controlling the daemon is equivalent to **root on the host**
[\[11\]](#ref-11). Membership of the `docker` group is the same power under another name. Rootless
Docker removes that: the daemon and every container run inside the runner user's **user
namespace**, where container "root" maps to an unprivileged host uid, so a container escape lands
as that unprivileged user and cannot load kernel modules, edit system files, or read other users'
data [\[4\]](#ref-4). The blast radius of a compromised job is the runner user, not the machine.
That containment is the reason this module is rootless-first. The boundary is structural: the
kernel's user namespace enforces it on every container, with no operator action to forget.

### What the module locks down

- No `docker` group and no root daemon: the daemon runs under the runner user's own
  `systemd --user` manager, and its socket lives in that user's `/run/user/<uid>` tree, private to
  the uid.
- No competing root daemon: the rootful `docker.service`/`docker.socket` and the idle root
  `containerd.service` that the `docker-ce`/`containerd.io` packages start as root are stopped and
  masked, so the only container daemon on the host is the rootless one.
- Only the runner user (with its `DOCKER_HOST`) reaches the daemon; the system-wide `docker` CLI
  is inert for everyone else.
- The runner **manager service** drops to the runner user as its reference posture
  (`service_user`), so not even the manager runs as root.
- Runner **tokens** are handled as `Sensitive` values and stay file-private to the runner uid (see
  [Secrets](#secrets)).

### Keeping the daemon socket out of jobs

The one setting that punctures this boundary is bind-mounting the daemon socket into job
containers. A job that reaches the socket controls the daemon *as the runner user*: it can start
further containers and read the runner token [\[11\]](#ref-11). Prefer a socketless build path
(BuildKit in rootless mode [\[28\]](#ref-28)) where you can. Where a runner genuinely needs it, configure
the `socket_mount` / `allowed_images` knobs in the [Configuration contract](#configuration-contract),
and leave `privileged` off.

## Secrets

Secrets (the runner `glrt-` tokens) are **never committed**.
They live in a single root-owned file on the host and are read by Hiera at apply time. That file
is just another **Hiera data layer**, so Puppet consumes it exactly like every other value; there
is nothing bespoke to learn.

The module **never talks to the GitLab API**: a runner is created in GitLab first (UI or API),
and its pre-created authentication token (`glrt-…`) is deployed to the host through the secret
store. This is the GitLab-native direction (registration tokens are deprecated), and it keeps
the apply loop free of network dependencies: the host only ever holds its own least-privilege
runner token, never a GitLab credential that could register or delete runners.

*Standalone only. In a fleet, catalogs compile on the Puppet server, so the host-local file
described below is inert there.* Fleet consumers supply
`rootless_gitlab_runner::tokens` through their server-side secrets machinery instead (for
example [hiera-eyaml](https://github.com/voxpupuli/hiera-eyaml)); everything else in this
section (the `token_key` indirection, blank-render versus fail-loud, the token at rest)
applies unchanged.

### Why use a secret file over environment variables

Beyond staying out of git, the goal is to keep tokens out of the process environment. As a Hiera
data layer, a YAML file is safer and simpler than environment variables here:

- Environment variables bleed into job containers and child processes and are readable via
  `/proc/<pid>/environ`, an exposure best avoided for runner tokens on a build host.
- Feeding env vars into `puppet apply` needs an `EnvironmentFile=`, itself just a less-structured
  secret file with extra indirection that still lands the secret in the environment. Hiera reads
  YAML directly.
- A YAML file also has a direct encryption-at-rest path (SOPS [\[7\]](#ref-7), on the roadmap); env vars do not.

### The secret file

Path `/etc/gitlab-runner-infra/secrets.yaml`, root-owned, mode `0600`. It holds one Hiera key: a
map of `token_key` to runner token. It is the hierarchy's off-repository layer — **never commit it**;
[`examples/secrets.example.yaml`](examples/secrets.example.yaml) is a starting template, and a
hiera-eyaml backend encrypts it at rest.

```yaml
---
rootless_gitlab_runner::tokens:
  runner_a: 'glrt-REDACTED'      # token for the runner whose token_key is 'runner_a'
```

The top-level key must be exactly `rootless_gitlab_runner::tokens`. A store file that exists but
uses a different top-level key (a bare `tokens:`, or a typo) resolves as an *absent* store, not an
error: tokens render blank per the empty-store contract that lets a checkout without secrets still
compile, and the mistake only shows up when the runner cannot reach GitLab. Check that key first
when a populated store still renders blank tokens.

**Sensitive by type:** The module types the token store `Sensitive` and ships a
`convert_to: Sensitive` lookup rule, so whether that file is plain YAML or
hiera-eyaml-encrypted, tokens are wrapped automatically on lookup (you write
ordinary Hiera data) and are redacted from the compiled catalog, Puppet reports, and
`--show_diff` output. For encryption at rest, a hiera-eyaml backend works on a
standalone host too (it is just a Hiera backend, read by `puppet apply` like any other);
SOPS is on the roadmap [\[7\]](#ref-7).

Each runner in the Hiera node file refers to its secret by **`token_key`**, never by value:

```yaml
# puppet/data/nodes/<hostname>.yaml
rootless_gitlab_runner::runners:
  - name: 'docker-socket-runner'
    token_key: 'runner_a'        # resolved from tokens['runner_a'] at apply time
    # ...
```

At apply time the module merges `tokens['runner_a']` into that runner and writes it into the
rendered runner config under `/etc` (`0600`). A checkout without the secret file renders blank
tokens instead of failing, so dry-runs and CI validation work anywhere. With a secret store
present, a `token_key` that resolves to nothing fails the apply with the key and runner
name, so a typo'd key or a missed provisioning step surfaces immediately instead of silently
registering a runner with a blank token.

**The token at rest:** The rendered config is owned by the runner user, mode `0600`, so the file
permissions *are* the token's at-rest protection: whatever can act as that uid can read it. That
is one more reason to keep the Docker socket out of job containers: a job that reaches the
socket can become the runner uid and read the token. Note also that GitLab Runner re-checks its
config **every 3 seconds** and reloads it automatically, so nothing ever needs to restart or
script around the service to pick up a re-rendered config.

### Editing the secret store

On the host, as root. The module manages the secret directory itself (root-owned, `0700`) on
every apply; before the first apply, create it by hand:

```
sudo install -d -m 0700 /etc/gitlab-runner-infra
```

Add or update entries under `rootless_gitlab_runner::tokens`:

```
sudoedit /etc/gitlab-runner-infra/secrets.yaml
```

Restrict the file to root:

```
sudo chmod 0600 /etc/gitlab-runner-infra/secrets.yaml
```

Every edit is followed by an apply to re-render the runner config (see
[Applying the configuration](#applying-the-configuration)); the running service picks up the
re-rendered config on its own within 3 seconds.

The token never enters git, the systemd unit, or the process environment.

## Installation

*Standalone only. Fleet consumers install the module like any other
(`include rootless_gitlab_runner`) and can skip this section.*

This module is consumed from a small **control repository** per site: a `Puppetfile` pinning this
module by `:commit`, a `hiera.yaml`, a `site.pp` with `include rootless_gitlab_runner`, and the
Hiera node data. A ready-to-adapt skeleton of that layout ships with the module in
[`examples/`](examples/) — the `Puppetfile`, `hiera.yaml`, `site.pp`, and `data/` assemble into
the control repository (see [`examples/README.md`](examples/README.md) for the layout). Copy them,
replace the Puppetfile's `:commit` placeholder and the example host data, and you have a control
repository. Bootstrapping a host (run as root):

1. Install OpenVox 8 (the community Puppet distribution [\[3\]](#ref-3)), git and r10k (a
   Puppet-brand `puppet-agent` 8 works identically if preferred).

   Download the OpenVox apt-repository package for Ubuntu 22.04:

   ```
   wget https://apt.voxpupuli.org/openvox8-release-ubuntu22.04.deb
   ```

   Install it to enable the repository:

   ```
   sudo apt install ./openvox8-release-ubuntu22.04.deb
   ```

   Install the agent, git and r10k (r10k ships in Ubuntu's own `universe` component):

   ```
   sudo apt update && sudo apt install openvox-agent git r10k
   ```
2. Get the control repository onto the host.

   Clone it to a root-owned path:

   ```
   sudo git clone <control-repository-url> /opt/<control-repository>
   ```

   Change into the checkout:

   ```
   cd /opt/<control-repository>
   ```

   Fetch the modules pinned in its Puppetfile (this module and its dependencies):

   ```
   sudo r10k puppetfile install --puppetfile Puppetfile --moduledir puppet/modules
   ```
3. Create the off-repository secret store `/etc/gitlab-runner-infra/secrets.yaml` (`0600`) with the
   runner tokens (see [Secrets](#secrets)).
4. Add a Hiera node file `puppet/data/nodes/<hostname>.yaml`, where `<hostname>` is the host's
   short hostname (the `networking.hostname` fact), describing the runners (start from
   [`examples/data/nodes/host.example.yaml`](examples/data/nodes/host.example.yaml)).
5. Decide what the module manages on this host. Leave a `manage_*` toggle off to treat that
   concern as an external prerequisite the host already provides; turn it on to have the module
   set it up and keep it converged on every apply. See the toggle table under
   [Configuration contract](#configuration-contract).
6. Dry-run first to preview the changes without touching the host (from the control-repository
   checkout). The absolute path is required: OpenVox installs outside `sudo`'s default
   `secure_path`, so a bare `puppet` is not found:

   ```
   sudo /opt/puppetlabs/bin/puppet apply --noop --confdir /etc/gitlab-runner-infra/puppet --vardir /var/lib/grunner-puppet --modulepath puppet/modules --hiera_config puppet/hiera.yaml puppet/manifests/site.pp
   ```

7. If the preview looks right, apply for real (same command without `--noop`).
8. Optionally set `manage_standalone_self_update: true` to have the module install the apply
   script and timers that automate future applies (see
   [Automating with systemd](#automating-with-systemd)).
9. Check the result (see [Verifying the host](#verifying-the-host)).

Each `manage_*` toggle decides whether the module owns a concern and keeps it converged (on) or
treats it as an external prerequisite the host must provide (off). The semantics and the full
toggle table are in the [Configuration contract](#configuration-contract).

Because Puppet is idempotent, the same flow works on a **fresh host or an existing one**: each run
converges to the declared state and corrects drift, so it is safe to repeat.

## Applying the configuration

*Standalone only. In a fleet, the Puppet server (or existing apply pipeline) runs it
instead of the apply script and service below.*

Run as root on the host.

With `manage_standalone_self_update` on, the module installs
`/usr/local/sbin/rootless-gitlab-runner-apply` — the **single definition of the apply command**.
It runs `puppet apply` with an isolated `--confdir`/`--vardir` so it never collides with a
central Puppet agent, installs Puppetfile-pinned modules via r10k first (a no-op without a
Puppetfile), and forwards extra arguments to Puppet. The systemd apply service and manual runs
both use it, so the invocation is defined in exactly one place.

First, preview the changes without touching the host:

```
sudo /usr/local/sbin/rootless-gitlab-runner-apply --noop
```

`--noop` is forwarded to `puppet apply`, so it previews the host changes without making them.
It does not suppress the module-install step: when a `Puppetfile` is present the script runs
`r10k puppetfile install` first, which still updates the pinned modules on disk before the
preview.

Once the preview looks right, apply (idempotent):

```
sudo /usr/local/sbin/rootless-gitlab-runner-apply
```

The script uses `--detailed-exitcodes` [\[1\]](#ref-1): exit code 0 means no changes, 2 means changes were
applied (success, not failure), 4 or 6 mean failures.

With the self-update units installed, prefer triggering a run through the apply service
rather than the script directly. It goes through the same fetch + signature-verify chain the
timer uses and serialises against it — the oneshot never overlaps a scheduled run:

```
sudo systemctl start gitlab-runner-apply.service
```

Running the script directly bypasses that serialisation and the fetch/verify step; keep it for
`--noop` previews and ad-hoc local runs.

Before the script exists (the first apply on a fresh host, or with the self-update toggle off),
use the plain `puppet apply` invocation from step 6 of [Installation](#installation).

### Restarts and graceful shutdown

A configuration change never restarts the runner: GitLab Runner re-reads `config.toml` within
about 3 seconds on its own. The only thing that restarts the manager is a change to its systemd
unit files (for example the module's privilege-drop drop-in). Where the module manages the runner
service, that restart sends **SIGQUIT** [\[20\]](#ref-20), which GitLab Runner treats as a graceful shutdown: it
stops taking new jobs and lets running ones finish instead of aborting them, which systemd's
default SIGTERM would do. Tune it with `service_kill_signal` and `service_timeout_stop_sec` — set
`TimeoutStopSec` [\[21\]](#ref-21) to the longest job a drain should wait for before systemd escalates to SIGKILL
(GitLab's documented example is `7200`; unset, systemd's default of roughly 90s applies).

### Automating with systemd

*Standalone only. In a fleet, your Puppet server (or existing apply pipeline) already
provides continuous convergence.*

With `manage_standalone_self_update` on, the module installs and keeps converged the full
self-update loop: the apply script above, `gitlab-runner-apply.service` + `.timer` (fetch,
verify the commit signature, reset to the remote branch, apply, default every 5 minutes), and
`gitlab-runner-healthcheck.service` + `.timer`. Nothing needs to be copied or enabled by hand;
the timers are started and enabled by the apply that installs them.

systemd serialises runs (a oneshot service never overlaps itself, so no external locking is
needed), and `SuccessExitStatus=2` treats Puppet's "changes applied" exit code as success, so only
genuine failures are flagged. A failure leaves the unit in the failed state, visible in the
journal, in `systemctl list-units --failed`, and to any host monitoring that watches failed
units. For a push alert, set `on_failure_unit` to a systemd unit of your own (e.g.
`notify-failure@%n.service`); the module renders it as `OnFailure=` on both the apply and
healthcheck services, so a failed tick activates it.
Auto-deploying `main` this way is safe because `main` is protected (merge request review plus a
required green pipeline) and only signed commits pass the `git verify-commit` gate, which
depends on the trust chain in [Self-update prerequisites](#self-update-prerequisites) below.

### Self-update prerequisites

*Standalone only — these prerequisites (the pull credential and the whole commit-signing trust
chain) matter only with `manage_standalone_self_update` on. A host without the self-update loop
(a fleet host, or standalone without the timers) needs none of them.*

The self-update loop fetches and verifies the control repository before it applies, so three
things must be provisioned on the host first. The module does not create them; if any is
missing the loop fails loud on its first tick, by design: a broken trust chain must never
silently apply.

Signature verification is non-optional within the loop, by design: it is what makes unattended
auto-apply safer. To run without it, leave `manage_standalone_self_update` off and apply another
way (plain `puppet apply`, or an operator's own timer).

1. **A pull credential:** The apply service fetches `origin` as root. Provision a **read-only,
   project-scoped SSH deploy key** [\[26\]](#ref-26) in root's `~/.ssh` (with the matching `known_hosts`) so the
   fetch authenticates non-interactively. A missing or dead credential is caught by the
   healthcheck's staleness check: an unreachable origin fails loud rather than hiding behind a
   green apply timer.
2. **A pinned signature trust root:** The loop runs `git verify-commit` [\[24\]](#ref-24) on the branch tip and
   applies only if it passes. `verify-commit` checks the signature against root's configured
   trust root, and an **empty keyring makes every commit fail**. Provision the trusted signer
   set explicitly and **pin it** (root-owned): an SSH allowed-signers file
   (`gpg.ssh.allowedSignersFile`) [\[25\]](#ref-25) for SSH-signed commits, or the GPG keyring for GPG-signed
   commits. Pin only the keys you trust to author **control-repository** deploys (it is the control
   repository's branch tip that is verified — the module itself is pinned separately, by `:commit`
   SHA in the Puppetfile); `verify-commit` otherwise accepts *any* key in the trust root.

   For SSH-signed commits, add one line per trusted deploy author to root's allowed-signers
   file — the committer email, then that person's signing public key:

   ```
   echo 'user@example.com ssh-ed25519 AAAA...' | sudo tee -a /root/.ssh/allowed_signers
   ```

   Point root's git at the file (the apply service runs `git verify-commit` as root, so
   root's global git config is what it reads):

   ```
   sudo git config --global gpg.ssh.allowedSignersFile /root/.ssh/allowed_signers
   ```
3. **A merge method that keeps the branch tip signed:** GitLab's default **merge-commit** method
   creates the merge commit **on the server, unsigned** unless instance/project web-commit
   signing is configured, so the tip of the protected branch would fail `verify-commit` even
   when every contributor signs. Use the **fast-forward** merge method (no server merge commit;
   the tip stays your signed commit) [\[9\]](#ref-9), or enable GitLab's web-commit signing
   [\[10\]](#ref-10), so the branch tip is always verifiable.

### Rolling back a commit

*Standalone only. In a fleet, roll back through the Puppet server's normal deploy path.*

The self-update loop applies whatever signed commit sits at the tip of the protected branch, so a
rollback is an ordinary git operation on the control repository, not a host action.

Revert on the control repository, then merge it the same reviewed, signed way as any change:

```
git revert <bad-sha>
```

The next apply tick fetches, verifies the signature on the new tip, resets to it, and applies, which
converges the host back. Because the loop **verifies before it mutates**, an unsigned or
unverifiable revert never applies: the revert must be signed and reach the branch tip through the
same merge-method constraint as any other change (above).

Two behaviors here are deliberate, not bugs:

- **Freshness over availability:** If the fetch or `verify-commit` fails — dead pull credential,
  unsigned tip, unreachable origin — the apply halts rather than applying stale or unverified
  state, and the healthcheck's staleness check turns a silently stuck host into a failed unit. A
  host that cannot prove it is current stops converging on purpose.
- **Self-modification:** The loop re-applies the very module that defines the apply units, so a
  commit that breaks those units can stop future ticks. Recover by running one apply by hand
  against a fixed commit — it re-lays the units and restarts the loop:

```
sudo systemctl start gitlab-runner-apply.service
```

### Verifying the host

A few checks, as root.

Confirm nothing is in a failed state:

```
systemctl list-units --failed
```

Confirm the apply and healthcheck timers are scheduled (with the self-update toggle on):

```
systemctl list-timers 'gitlab-runner-*'
```

Confirm rootless Docker answers as the runner user:

```
runuser -u gitlab-runner -- env "XDG_RUNTIME_DIR=/run/user/$(id -u gitlab-runner)" "DOCKER_HOST=unix:///run/user/$(id -u gitlab-runner)/docker.sock" docker info
```

That `runuser`/`env` shape is not optional decoration: the runner is a **no-login system user**,
so a plain `su`/`sudo -u` shell has no systemd user session, so `XDG_RUNTIME_DIR` and
`DOCKER_HOST` must point explicitly at its `/run/user/<uid>` tree to reach the rootless daemon (the module's
own healthcheck script wraps its checks in the same incantation; adjust the socket path if you
set a non-default `docker_socket_path`).

Confirm every configured runner reaches GitLab with a valid token:

```
gitlab-runner verify
```

[`gitlab-runner verify`](https://docs.gitlab.com/runner/commands/#gitlab-runner-verify) asks
GitLab whether each registered runner can connect; run it by hand after rotating tokens. The
module's healthcheck timer does not run `verify`; it checks the manager service, the rootless
Docker daemon (as the runner user), that the apply timer is still enabled and armed, and checkout
staleness against the remote, surfacing failures as failed units. Token validity is the one check
you make manually.

On the GitLab Runners page, a connected runner turns green and is shown online. A runner always
appears once created, so it is that online state, not its mere presence, that confirms the host
reached GitLab.

## Lifecycle operations

Managing runners on a host that is already set up, in the order these tasks come up. Everything
follows the same rule as the rest of the module: what enters the data appears on the host, what
leaves the data leaves the host (see [Configuration contract](#configuration-contract)). The
runner's GitLab-side record and anything a `manage_*` toggle set up are the two things an apply
never removes.

### Adding a runner

One prescribed order: the token must exist in the host's secret store before the runner
entry appears in the data:

1. Create the runner in GitLab (in the UI, or via
   [`POST /user/runners`](https://docs.gitlab.com/api/users/#create-a-runner-linked-to-a-user))
   and copy its `glrt-` authentication token.
2. Put the token into the host's secret store under a new `token_key` (see
   [Editing the secret store](#editing-the-secret-store)).
3. Only now add the runner entry with that `token_key` to the node's Hiera data and merge it.
4. Apply, or let the timer pick it up.

The order matters: with a secret store present, an entry whose `token_key` resolves to nothing
fails the apply, and with the timer on it recurs visibly every 5 minutes until the token
lands. Put the token in first and the data second: an unused token in the store is harmless, but
data pointing at a missing token fails every apply until you fix it.

**Note:** Creating the runner (as described in step 1) is deliberately a manual UI or
[`POST /user/runners`](https://docs.gitlab.com/api/users/#create-a-runner-linked-to-a-user) step —
the module never calls the GitLab API to do it. A runner is created seldom enough that automating
it earns little, and leaving it manual keeps the `create_runner`-scoped credential such automation
would need off the host, which holds only its own runner token (see [Secrets](#secrets)). The
deprecated registration-token flow is likewise unused.

### Rotating a token

Reset the token in GitLab first, on the runner's page in the UI, or via the API:
[`POST /runners/:id/reset_authentication_token`](https://docs.gitlab.com/api/runners/#reset-runners-authentication-token-by-using-the-runner-id)
(needs a `manage_runner`-scoped access token) or
[`POST /runners/reset_authentication_token`](https://docs.gitlab.com/api/runners/#reset-runners-authentication-token-by-using-the-current-token)
(authenticated by the current runner token itself). Then update the entry in the secret store
(see [Editing the secret store](#editing-the-secret-store)) and **apply immediately**: the old
token stops working at the reset, and the runner only regains a valid one when the config is
re-rendered. No restart is involved; the runner notices the new config within 3 seconds.

### Removing a runner

1. Delete the runner's entry from the node's Hiera data and merge the change.
2. Apply (or let the timer): the entry disappears from `config.toml`, and the runner manager
   drops it within seconds (the 3-second config reload).
3. Delete the runner in GitLab, or its record and token stay live: the runner's page in
   the UI, or [`DELETE /runners/:id`](https://docs.gitlab.com/api/runners/#delete-a-runner-by-id),
   or [`DELETE /runners`](https://docs.gitlab.com/api/runners/#delete-a-runner-by-authentication-token)
   authenticated by the runner token.
4. Remove its entry from the secret store.

### Retiring the host

1. *Standalone only:* **disable the self-update loop first**, or the next 5-minute tick reinstates
   whatever is removed:

   ```
   sudo systemctl disable --now gitlab-runner-apply.timer gitlab-runner-healthcheck.timer
   ```

   On a fleet host the equivalent first step is unenrolling the node, so the Puppet agent stops
   converging it.
2. Stop the runner: `sudo systemctl disable --now gitlab-runner`.
3. Delete the host's runners in GitLab (step 3 of [Removing a runner](#removing-a-runner)) and
   delete `/etc/gitlab-runner-infra/`.
4. What remains is the module's last applied state: the packages from `packages`, and, if
   their toggles were on, the runner user with its home and the rootless-Docker setup. The
   module has no `ensure => absent` mode; remove these with the usual host tools if the machine
   is repurposed, or reimage.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) describes the development
environment, syntax validation, linting and unit tests, the layout of the code, and the
CI/CD pipeline.

The module targets GitLab Runner but lives on GitHub, deliberately: the Puppet module ecosystem —
the Forge, Vox Pupuli, and the shared CI and conventions this repository follows — is almost
entirely GitHub-based, so it is most discoverable there.

## Roadmap

Planned or under evaluation, not yet implemented:

- **Encrypted secrets (SOPS):** The off-repository secret store is currently plain, root-owned YAML
  (`0600`). SOPS-based encryption is planned, with decryption handled in the apply wrapper so the
  Puppet code stays unchanged.
- **Ubuntu 24.04 support:** 24.04 enables `kernel.apparmor_restrict_unprivileged_userns` by
  default and requires an AppArmor profile for rootless containers. Supporting it is a future
  consideration; the module currently targets Ubuntu 22.04.

## License

[Apache License 2.0](LICENSE). Copyright © 2026 ETH Zurich, Jaime Cardozo.

## References

- <a id="ref-1"></a>\[1\] **Standalone Puppet (`puppet apply`)**: applying manifests directly on a
  node, without a Puppet server.
  [Puppet: `puppet apply`](https://help.puppet.com/core/8/Content/PuppetCore/Markdown/apply.htm)
- <a id="ref-2"></a>\[2\] **Hiera**: Puppet's hierarchical key-value lookup that keeps data separate
  from code. [Puppet: Hiera](https://help.puppet.com/core/8/Content/PuppetCore/hiera_intro.htm)
- <a id="ref-3"></a>\[3\] **OpenVox**: the community fork of Puppet that runs on the host.
  [OpenVox](https://github.com/OpenVoxProject/openvox)
- <a id="ref-4"></a>\[4\] **Rootless Docker**: running the Docker daemon as a non-root user.
  [Docker: rootless mode](https://docs.docker.com/engine/security/rootless/)
- <a id="ref-5"></a>\[5\] **GitLab Runner**: the agent that executes GitLab CI/CD jobs.
  [GitLab Runner docs](https://docs.gitlab.com/runner/)
- <a id="ref-6"></a>\[6\] **systemd timers**: systemd's mechanism for scheduling unit activation, an
  alternative to cron.
  [systemd.timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)
- <a id="ref-7"></a>\[7\] **SOPS**: a tool for encrypting secrets at rest (see [Roadmap](#roadmap)).
  [getsops/sops](https://github.com/getsops/sops)
- <a id="ref-8"></a>\[8\] **r10k**: Puppet control-repository and environment deployment tool.
  [puppetlabs/r10k](https://github.com/puppetlabs/r10k)
- <a id="ref-9"></a>\[9\] **GitLab merge methods**: fast-forward vs merge-commit, and their effect
  on history. [GitLab Docs — Merge methods](https://docs.gitlab.com/user/project/merge_requests/methods/)
- <a id="ref-10"></a>\[10\] **Signed commits from the GitLab UI**: instance/project web-commit
  signing. [GitLab Docs](https://docs.gitlab.com/user/project/repository/signed_commits/web_commits/)
- <a id="ref-11"></a>\[11\] **Docker daemon attack surface**: why controlling the daemon (or its
  socket) is equivalent to root on the host.
  [Docker Docs](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)
- <a id="ref-12"></a>\[12\] **Subordinate UID/GID ranges**: the `/etc/subuid` and `/etc/subgid`
  allocations a user namespace maps. [subuid(5)](https://man7.org/linux/man-pages/man5/subuid.5.html)
- <a id="ref-13"></a>\[13\] **`newuidmap`/`newgidmap`**: setuid helpers that write a user
  namespace's UID/GID maps. [newuidmap(1)](https://man7.org/linux/man-pages/man1/newuidmap.1.html)
- <a id="ref-14"></a>\[14\] **Lingering**: `systemd-logind` keeping a user's manager running with
  no active login. [loginctl(1)](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html)
- <a id="ref-15"></a>\[15\] **cgroup v2**: the kernel's unified control-group hierarchy.
  [Kernel: Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)
- <a id="ref-16"></a>\[16\] **`overlay2`**: Docker's default OverlayFS storage driver.
  [Docker: OverlayFS storage driver](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
- <a id="ref-17"></a>\[17\] **`fuse-overlayfs`**: a FUSE OverlayFS implementation usable rootless on
  older kernels. [containers/fuse-overlayfs](https://github.com/containers/fuse-overlayfs)
- <a id="ref-18"></a>\[18\] **`DOCKER_HOST`**: the environment variable selecting the daemon socket
  the Docker client connects to. [Docker CLI: environment variables](https://docs.docker.com/reference/cli/docker/#environment-variables)
- <a id="ref-19"></a>\[19\] **`XDG_RUNTIME_DIR`**: the per-user runtime directory (`/run/user/<uid>`).
  [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/)
- <a id="ref-20"></a>\[20\] **GitLab Runner signals**: `SIGQUIT` requests a graceful shutdown —
  finish running jobs, then exit. [GitLab Runner: signals](https://docs.gitlab.com/runner/commands/#signals)
- <a id="ref-21"></a>\[21\] **`KillSignal`/`TimeoutStopSec`**: systemd's stop-signal and
  stop-timeout directives. [systemd.kill(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html)
- <a id="ref-22"></a>\[22\] **`DETACH_NETNS`**: RootlessKit's detached-network-namespace mode
  (NETNS = network namespace). [RootlessKit: detaching network namespace](https://github.com/rootless-containers/rootlesskit/blob/master/docs/network.md#detaching-network-namespace)
- <a id="ref-23"></a>\[23\] **Restricting job images**: the Docker executor's `allowed_images`.
  [GitLab Runner: restrict Docker images](https://docs.gitlab.com/runner/executors/docker/#restrict-docker-images-and-services)
- <a id="ref-24"></a>\[24\] **`git verify-commit`**: verifies a commit's GPG/SSH signature.
  [git-verify-commit](https://git-scm.com/docs/git-verify-commit)
- <a id="ref-25"></a>\[25\] **Allowed-signers file**: the `allowed_signers` format SSH signature
  verification reads. [ssh-keygen(1) — ALLOWED SIGNERS](https://man.openbsd.org/ssh-keygen.1#ALLOWED_SIGNERS)
- <a id="ref-26"></a>\[26\] **SSH deploy key**: a read-only, project-scoped key for fetching a
  repository. [GitLab: deploy keys](https://docs.gitlab.com/user/project/deploy_keys/)
- <a id="ref-27"></a>\[27\] **Network namespaces**: the kernel isolation giving a process group its
  own network devices, routing and firewall rules.
  [network_namespaces(7)](https://man7.org/linux/man-pages/man7/network_namespaces.7.html)
- <a id="ref-28"></a>\[28\] **BuildKit**: Docker's build backend; supports rootless, daemonless
  image builds. [Docker: BuildKit](https://docs.docker.com/build/buildkit/)
- <a id="ref-29"></a>\[29\] **D-Bus**: the message bus system; `dbus-user-session` provides its
  per-user session daemon, which `systemd --user` integration needs.
  [freedesktop.org: D-Bus](https://www.freedesktop.org/wiki/Software/dbus/)
- <a id="ref-30"></a>\[30\] **Docker Engine**: the containerization engine and daemon that runs
  the job containers. [Docker Engine](https://docs.docker.com/engine/)
- <a id="ref-31"></a>\[31\] **Docker CLI**: the `docker` command-line client.
  [Docker CLI reference](https://docs.docker.com/reference/cli/docker/)
- <a id="ref-32"></a>\[32\] **containerd**: the industry-standard container runtime the Docker
  daemon builds on. [containerd](https://containerd.io/)
