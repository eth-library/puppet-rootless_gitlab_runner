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
- [Standalone deployment](#standalone-deployment)
- [Prerequisites](#prerequisites)
  - [Host requirements](#host-requirements)
- [Configuration contract](#configuration-contract)
  - [Managed concerns](#managed-concerns)
  - [Opt-in concerns](#opt-in-concerns)
  - [File layout](#file-layout)
  - [Declaring runners](#declaring-runners)
  - [Validating Hiera data in CI](#validating-hiera-data-in-ci)
- [Security](#security)
  - [Why rootless](#why-rootless)
  - [What the module locks down](#what-the-module-locks-down)
  - [Keeping the daemon socket out of jobs](#keeping-the-daemon-socket-out-of-jobs)
- [Secrets](#secrets)
- [Applying the configuration](#applying-the-configuration)
  - [Restarts and graceful shutdown](#restarts-and-graceful-shutdown)
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

The standalone runbook, [`docs/standalone.md`](docs/standalone.md), documents that path end
to end; a fleet consumer adds the Puppetfile entry and provides the same Hiera data and
secret store through their control repository and server-side machinery.

No established Puppet module appears to manage a rootless GitLab Runner host end to end. The
existing
[`voxpupuli/puppet-gitlab_ci_runner`](https://github.com/voxpupuli/puppet-gitlab_ci_runner) has no
rootless path, so the entire stack would have to be built on top; that stack is exactly what this
module packages. It is the opinionated rootless-first alternative, with an optional signed
self-update loop: a host tracks its own signed control-repository branch and re-applies on a timer,
so it stays converged on its own. That makes it an easy on-ramp for hosts with no full
r10k/Puppet-server fleet behind them.

## Quick start

The fastest path on a fleet host, one already managed by a Puppet server (or any
control-repository/r10k setup):

1. Add this module to the control repository's `Puppetfile`, pinned by `:commit`, together
   with its `puppetlabs/stdlib` and `puppetlabs/apt` dependencies (the example
   [`Puppetfile`](examples/Puppetfile) carries the lines), and declare the class from a role
   or profile: `include rootless_gitlab_runner`.
2. Add the Hiera data: copy [`examples/data/`](examples/data/) into the control repository's
   hierarchy and adjust the node file's per-host values.
3. Create each runner in GitLab (UI or API) and copy its `glrt-` authentication token
   ([Adding a runner](#adding-a-runner)).
4. Supply the tokens as `rootless_gitlab_runner::runner_tokens` through the server-side
   secrets machinery, for example hiera-eyaml ([Secrets](#secrets)).
5. Let the agent apply on its normal schedule, then verify: the runner turns green and shows
   online on GitLab's Runners page ([Verifying the host](#verifying-the-host)).

The standalone flow lives in [`docs/standalone.md`](docs/standalone.md).

## Operating model

> [!TIP]
> **Use a dedicated host for the GitLab Runner.** Its only job should be running the runners,
> ideally on a disposable, rebuildable VM. To harden the runner the module takes over
> host-level state: with `rootless_docker.manage` on it masks the host's rootful Docker and containerd daemons, and
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
- **Standalone only:** the optional self-update loop can automate those runs on a systemd
  timer [\[6\]](#ref-6); a standalone host without the loop applies manually through the
  apply script, and a fleet host uses neither, because the Puppet server's agent already
  provides that continuous convergence (see the [standalone runbook](docs/standalone.md)).

## Standalone deployment

A standalone host applies itself with `puppet apply` from a control-repository checkout
instead of being deployed by a Puppet server; the same control repository can drive one such
host or several. Everything on this page (the configuration contract, secrets, and security
model) applies unchanged; the bring-up and operations runbook is
[`docs/standalone.md`](docs/standalone.md).

## Prerequisites

The module targets **Ubuntu 22.04** with **Puppet/OpenVox 8** [\[3\]](#ref-3) (see `metadata.json`
for the exact supported version range). Before an apply does anything useful, the host needs:

- **Puppet (or OpenVox) 8** installed and `puppet` on `PATH`.
- The **`gitlab-runner` system user and home**, plus its **rootless-Docker** user daemon,
  unless the module manages them: with `runner_account.manage` off the user is an external
  prerequisite (owned elsewhere, for example by a central Puppet), and with
  `rootless_docker.manage` off the daemon and its host requirements are.

What the module owns on a host is configuration too; the ownership toggles and their parameters
live in the [Configuration contract](#configuration-contract).

### Host requirements

A rootless GitLab Runner host needs the following in place. With `runner_account.manage` and
`rootless_docker.manage` on, the module establishes and keeps converging them (apt packages by
listing them under `packages.install`); with the toggles off they are external prerequisites the host must
provide, and the preflight is not enforced — so a missing prerequisite on the toggle-off path
surfaces as a raw Puppet or host error rather than the module's clear preflight message. On Ubuntu
22.04 these are the current, verified requirements:

- **Subordinate IDs:** `/etc/subuid` and `/etc/subgid` [\[10\]](#ref-10) must each grant the runner
  user at least **65,536** IDs (165,536 for nested rootless BuildKit builds), for example
  `gitlab-runner:231072:165536`, the module's default range. A plain
  `useradd --system` does not reliably allocate these.
- **`uidmap` package:** Provides `newuidmap` and `newgidmap` [\[11\]](#ref-11), required for
  user-namespace mapping. It is not always pulled in automatically.
- **`dbus-user-session` package:** Lets `systemctl --user` work under lingering. [\[4\]](#ref-4)
- **Lingering:** `loginctl enable-linger` [\[12\]](#ref-12) for the runner user, so its systemd user
  manager and `XDG_RUNTIME_DIR=/run/user/<uid>` [\[17\]](#ref-17) exist at boot without an
  interactive login.
- **cgroup v2:** [\[13\]](#ref-13) The unified hierarchy, the default on 22.04, is required for the
  rootless daemon and for container resource limits.
- **Storage driver:** The `overlay2` driver [\[14\]](#ref-14) works rootless on kernel **5.11** or
  newer (jammy ships 5.15). On older kernels the fallback is `fuse-overlayfs` [\[15\]](#ref-15)
  (kernel 4.18 or newer, plus the `fuse-overlayfs` package).
- **Daemon connection (`DOCKER_HOST`):** [\[16\]](#ref-16) Required for every rootless job: it is how the runner
  manager reaches the rootless daemon to create job containers. Where the module manages the runner
  service it sets this automatically, deriving `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` from
  `runner_account.uid`. This is distinct from bind-mounting the socket into a
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
- **Package versions are neither pinned nor held** — `packages.install` uses `ensure => installed`. This
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
`DETACH_NETNS=false` [\[20\]](#ref-20) (NETNS stands for network namespace [\[22\]](#ref-22)). It fixes the recurring Ubuntu 22.04 breakage where a
rootless-Docker package upgrade silently breaks container networking (it is specific to that
platform, not a universal setting).

The substantial host bring-up (the rootless-Docker daemon, the runner user, the service) is opt-in
below.

### Opt-in concerns

The parameter surface groups each remaining concern into a struct whose `manage` key is the
ownership toggle, opt-in by default:

| Concern | Hiera key | Default |
|---|---|---|
| apt packages | [`packages.install`](#packages) | `[]` |
| apt sources serving those packages | [`packages.sources.manage`](#packagessources) | `false` |
| Runner account (group, user, home) | [`runner_account.manage`](#runner_account) | `false` |
| Rootless-Docker daemon bring-up, subordinate IDs | [`rootless_docker.manage`](#rootless_docker) | `false` |
| Runner service + its systemd drop-in | [`runner_service.manage`](#runner_service) | `false` |
| Standalone topology (apply script + liveness healthcheck) | [`standalone.manage`](#standalone) | `false` |
| Self-update loop | [`standalone.self_update.manage`](#standaloneself_update) | `false` |

The `manage` keys are **persistent ownership switches**, not one-shot bootstrap flags:
set once in the host's Hiera and left on, so every apply keeps owning and drift-correcting that
concern. `false` means hands-off, not ensure-off. A `manage` key decides whether the module
creates and enforces its concern's *resources*; most struct keys are consumed only by their own
concern, so they are inert while its `manage` is false, while `runner_account`'s identity keys
are shared inputs every concern reads.

#### Struct parameters and deep merge

Every subkey has a module-supplied default, and each struct parameter carries a deep-merge
lookup rule, so consumer data holds only deviations: a node file setting
`rootless_docker.manage: true` inherits the rest of that struct from the module defaults, and
different Hiera layers can each own different subkeys. Within a merged struct, a scalar subkey
set at a higher-priority layer wins and hashes merge recursively; array subkeys are **unioned**
across layers, and an element prefixed with `--` (the deep-merge knockout prefix) removes the
matching element a lower layer contributed. Removing a whole subkey through data is not
expressible: override it with the intended value instead. A mistyped subkey fails the compile
instead of being silently ignored. The documented consumption pattern is Hiera plus
`include rootless_gitlab_runner`; a resource-style class declaration bypasses Hiera merging and
must pass complete struct hashes.

#### `packages`

`packages.install` lists the apt packages to ensure installed; the default empty list installs
nothing, and the module only installs — it never removes, pins, or upgrades packages. A
rootless-runner host on Ubuntu 22.04 needs the user-namespace helper `uidmap`
[\[11\]](#ref-11) and `dbus-user-session` [\[24\]](#ref-24); the Docker Engine package
`docker-ce` [\[25\]](#ref-25), its CLI `docker-ce-cli` [\[26\]](#ref-26) and the rootless
extras `docker-ce-rootless-extras` (rootless mode [\[4\]](#ref-4)); `containerd.io`, which
packages the containerd runtime [\[27\]](#ref-27); and `gitlab-runner` [\[5\]](#ref-5). The
standalone [example host data](examples/data/nodes/host.example.yaml) lists the full set.
Their apt source is managed by [`packages.sources`](#packagessources) or provided externally.

#### `packages.sources`

With `packages.sources.manage` on, the module adds the Docker and GitLab Runner apt
repositories (with their signing keys) via `puppetlabs/apt`, so the `packages.install` list
installs on stock Ubuntu. Keep it off where apt sources are owned elsewhere. The
`packages.sources.docker` and `packages.sources.gitlab_runner` sub-hashes each carry
`location` and `key_source` (verbatim `apt::source` parameter names), overridden only to point
at a mirror; the defaults are the vendors' repositories and their rolling signing-key
endpoints. `puppetlabs/apt` is needed only by this toggle; `puppetlabs/stdlib` is needed
unconditionally. Consumers add both to their Puppetfile (r10k does not resolve module metadata
dependencies; the example skeleton carries the lines).

`packages.sources.manage` and `packages.install` are independent layers: the switch adds
the two vendor apt sources and their signing keys, and the list names what to install from
whatever sources the host has. On a host whose content platform (orcharhino,
Foreman/Katello) serves the packages, two shapes are supported: the platform owns the
sources and the module installs (`sources.manage: false`, keep `install`), or the platform
owns the packages too (`sources.manage: false`, `install: []`), with `docker-ce` and
`gitlab-runner` becoming external prerequisites. `packages.sources.manage: true` is the
stock-Ubuntu convenience for a host with no central content platform.

#### `runner_account`

The OS account the runner manager and the rootless daemon run as: `name`, an optional `group`,
`uid`, and `home`, with `manage` deciding ownership. The identity keys are read by every concern
even when `manage: false` (socket derivation, file ownership, service `ExecStart`); the toggle
only decides whether the module creates and enforces the group, user, and home. Keep `manage`
off where another configuration-management system owns the account; two owners would fight over
it. The subordinate UID/GID ranges rootless Docker needs are owned by
[`rootless_docker`](#rootless_docker), not this toggle. Home internals (`.ssh`, `.config`) are
never managed, beyond the no-detach-netns drop-in the module places under
`~/.config/systemd/user/`.

`uid` has no default: it is host data, set per host in the Hiera node file
([`host.example.yaml`](examples/data/nodes/host.example.yaml) sets it), and the rootless
runtime paths (`/run/user/<uid>`, the docker socket) derive from it. An apply that needs the
uid and finds it unset fails at compile time with a clear message; every concern but the
package layer needs it (`runner_account.manage`, `rootless_docker.manage`,
`runner_service.manage` or `standalone.manage` on, or a `socket_mount` runner).

`group` names the account's primary group and defaults to `name`. Set it for an externally
provisioned account whose primary group is named differently (e.g. account `ci-worker`, group `ci`):
it feeds every group ownership the module manages — the group resource and the user's primary
group where `manage` is on, and the group of the runner configuration file, its directory, and
the account's systemd user tree — so the first apply converges instead of failing to resolve a
group that does not exist. Left unset, the account name doubles as the group, which is correct
by construction where the module creates the account.

#### `rootless_docker`

With `rootless_docker.manage` on, the module brings up the rootless-Docker user daemon:
provisions the subordinate UID/GID ranges the daemon needs (`subid_start`/`subid_count`,
default `231072`/`165536`) and enforces `subid_count` as a grow-only minimum width. A
module-owned range at the declared start narrower than `subid_count` is widened in place by
adding the missing tail as a further contiguous range: a pure `usermod --add`, which grows the
range even while the runner user's session is live and leaves the existing mappings as an
untouched prefix. The rootless daemon is then restarted so its user namespace picks up the new
width; a foreign or already-wider range is never rewritten (a too-narrow foreign range fails the
preflight, a wide-enough one warns). Widening an in-service host
interrupts running jobs (rootless mode has no live-restore), so it is best scheduled around
them; CI-side job `retry` covers a job caught by the restart. It then enables lingering and runs
`dockerd-rootless-setuptool.sh install` [\[4\]](#ref-4) as the runner user (guarded on installed state, so it
runs only until the rootless daemon's user unit exists). The ranges are provisioned for the
runner user whether the module owns the account ([`runner_account`](#runner_account))
or another system does. The setuptool is upstream's
supported installer and ships in `docker-ce-rootless-extras`, version-locked to the daemon
it configures — the module invokes it rather than re-rendering its output, so the generated
user unit (`~/.config/systemd/user/docker.service`) can never drift out of step with the
installed Docker. That unit remains upstream's artifact; the module's sole modification to
it is the `no-detach-netns` drop-in, layered on top as a systemd override so both survive
the other changing.

The whole chain sits behind a fail-loud preflight that asserts the prerequisites (`newuidmap` present,
the runner user's subordinate IDs totalling at least the declared `subid_count`, lingering enabled,
cgroup v2) and aborts with a clear message — only active when `rootless_docker.manage` is `true`. On a host where everything is already in place the
chain is a no-op.

The toggle also **stops and masks the rootful system
`docker.service`/`docker.socket` and the idle root `containerd.service`** (which installing
`docker-ce`/`containerd.io` starts as root), so the only container daemon on the host is the
unprivileged one — see [Security](#security).

#### `runner_service`

With `runner_service.manage` on, the module owns the `gitlab-runner` system service, a
systemd drop-in for it (`/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf`), and
the mode on `/etc/gitlab-runner` so the privilege-dropped manager can read its own config. The
drop-in runs the manager privilege-dropped as the runner account — that is the module's
posture, not a knob — with `DOCKER_HOST` derived from `runner_account.uid`, so a managed
service requires that uid. `DOCKER_HOST` is module-owned and the same socket the healthcheck and
`socket_mount` use; `runner_service.environment` adds any further `Environment=` lines alongside
it (a `DOCKER_HOST` line there fails the compile; a runner whose jobs need a different daemon uses
the per-runner `host` key instead). `runner_service.timeout_stop_sec` sets the graceful-drain
window ([Restarts and graceful shutdown](#restarts-and-graceful-shutdown)).

#### `standalone`

`standalone.manage` declares the host standalone — a host that applies itself with
`puppet apply` from a control-repository checkout (`standalone.control_repository_path`),
rather than being deployed by a Puppet server. It installs the apply script
(`/usr/local/sbin/rootless-gitlab-runner-apply`), the single definition of the apply command
for manual runs and the self-update loop alike
([Applying the configuration](docs/standalone.md#applying-the-configuration) in the
runbook), and a liveness healthcheck
(script + timer, default every `15min`, `standalone.healthcheck_interval`) that verifies the
manager service and the rootless daemon (`docker info` as the runner user) — installed on any
standalone host, with or without the loop. The apply's manifest, module
directory and Hiera configuration derive from the documented control-repository layout
(`puppet/manifests/site.pp`, `puppet/modules`, `puppet/hiera.yaml` beneath the checkout); the
isolated Puppet state directories are `standalone.puppet_confdir`/`standalone.puppet_vardir`,
and `standalone.puppet_bindir` locates the `puppet`/`r10k` executables for the timer-driven,
non-login apply.

`control_repository_path` (default `/opt/gitlab-runner-infra`) is host data too: it names
wherever the checkout lives on that host. A wrong path is caught at runtime, by the
self-update fetch and the healthcheck's staleness assertion, not at compile time.

#### `standalone.self_update`

With `standalone.self_update.manage` on — only valid on a standalone host: enabling it with
`standalone.manage` off fails at compile time — the module installs the self-update loop: a
oneshot systemd service + timer (default every `5min`, `standalone.self_update.apply_interval`)
that fetch the control-repository checkout, run `git verify-commit` on the remote branch (only
signed commits are applied), reset to it, install Puppetfile-pinned modules via
`r10k puppetfile install` (a no-op without a Puppetfile), and re-apply through the apply script
above.

The loop also layers its own supervision onto the liveness healthcheck that `standalone.manage`
installs: it adds checks that the apply timer is enabled and armed, that the checkout is not
stale against the remote (a dead pull credential fails loud instead of leaving the host applying
old code behind a green timer), and that the bootstrap gems (`r10k`, `hiera-eyaml`) are present
in the AIO Ruby.

The service sets `HOME=/root` (git/SSH need it) and an explicit `TimeoutStartSec`
(`standalone.self_update.apply_timeout`); Puppet exit code 2 ("changes applied") counts as
success.

Never enable it where a Puppet server or r10k already deploys the host: the host would end
up with two deploy agents fighting over its state.

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
> unless a job must drive Docker, and constrain it with `allowed_images` [\[21\]](#ref-21) when it is on. See
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

- **Advisory, non-failing:** a subkey set under a hash parameter whose effective
  `manage` toggle resolves to `false` is recognized but not enforced as a resource
  (the module is hands-off that concern, though it may still read some subkeys as
  shared inputs; see the `manage`-key rule above). The toggle is resolved wherever
  it sits, at the top level or nested in a sub-hash (`packages.sources.manage`,
  `standalone.self_update.manage`), and over the module's own defaults, so a toggle
  left at its default is still caught. A value that differs from the module default
  is reported; a mere restatement of the default is treated as inert. The check
  reports these as an advisory rather than a failure (declaring the state of an
  externally owned concern can be intentional), and a human judges intent.
- **Stated limits:** the check validates key names, not values (types are the
  compiler's job, enforced at compile time), and it cannot see consumer data layers
  outside the repository, such as the off-repository secret store. The module
  defaults are read from static `path`/`paths` levels only. Hierarchy levels
  addressed by `glob`/`globs` or `mapped_paths` are not modeled; advisory resolution
  covers `path`/`paths` levels only.

The module's own [`examples/data/`](examples/data/) is held to the same rule by the unit
suite, so the shipped examples cannot drift from the parameter surface.

## Security

### Why rootless

A conventional Docker daemon runs as root, so anything that can reach its
socket controls the daemon, and controlling the daemon is equivalent to **root on the host**
[\[9\]](#ref-9). Membership of the `docker` group is the same power under another name. Rootless
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
- The runner **manager service** always drops to the runner account, so not even the manager
  runs as root.
- Runner **tokens** are handled as `Sensitive` values and stay file-private to the runner uid (see
  [Secrets](#secrets)).

### Keeping the daemon socket out of jobs

The one setting that punctures this boundary is bind-mounting the daemon socket into job
containers. A job that reaches the socket controls the daemon *as the runner user*: it can start
further containers and read the runner token [\[9\]](#ref-9). Prefer a socketless build path
(BuildKit in rootless mode [\[23\]](#ref-23)) where you can. Where a runner genuinely needs it, configure
the `socket_mount` / `allowed_images` knobs in the [Configuration contract](#configuration-contract),
and leave `privileged` off.

## Secrets

Secrets (the runner `glrt-` tokens) are **never committed**. They are supplied as another
**Hiera data layer**, so Puppet consumes them exactly like every other value and there is
nothing bespoke to learn: on a standalone host that layer is a root-owned file on the host
([The secret store](docs/standalone.md#the-secret-store) in the runbook); in a fleet it is
the server-side secrets machinery (for example
[hiera-eyaml](https://github.com/voxpupuli/hiera-eyaml)), since catalogs compile on the
Puppet server and a host-local file would be inert there.

The module **never talks to the GitLab API**: a runner is created in GitLab first (UI or API),
and its pre-created authentication token (`glrt-…`) is deployed to the host through the secret
store. This is the GitLab-native direction (registration tokens are deprecated), and it keeps
the apply loop free of network dependencies: the host only ever holds its own least-privilege
runner token, never a GitLab credential that could register or delete runners.

Whichever layer supplies them, it holds one Hiera key: a map of `token_key` to runner token
under `rootless_gitlab_runner::runner_tokens`
([`examples/secrets.example.yaml`](examples/secrets.example.yaml) is a starting template):

```yaml
---
rootless_gitlab_runner::runner_tokens:
  runner_a: 'glrt-REDACTED'      # token for the runner whose token_key is 'runner_a'
```

**Sensitive by type:** The module types the token store `Sensitive` and ships a
`convert_to: Sensitive` lookup rule, so whether the data layer is plain YAML or
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
rendered runner config under `/etc` (`0600`). A checkout without a secret store renders blank
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

## Applying the configuration

On a fleet host, the Puppet server's agent applies the catalog on its normal schedule. On a
standalone host, the module's apply script and its systemd automation do that job; the
runbook's [Applying the configuration](docs/standalone.md#applying-the-configuration) section
covers them. The behaviors below are shared by both paths.

### Restarts and graceful shutdown

A configuration change never restarts the runner: GitLab Runner re-reads `config.toml` within
about 3 seconds on its own. The only thing that restarts the manager is a change to its systemd
unit files (for example the module's privilege-drop drop-in). Where the module manages the runner
service, that restart sends **SIGQUIT** [\[18\]](#ref-18), which GitLab Runner treats as a graceful shutdown: it
stops taking new jobs and lets running ones finish instead of aborting them, which systemd's
default SIGTERM would do. The graceful-drain signal is fixed; the drain window is data — set
`runner_service.timeout_stop_sec` (systemd's `TimeoutStopSec` [\[19\]](#ref-19)) to the longest job a drain should
wait for before systemd escalates to SIGKILL
(GitLab's documented example is `7200`; unset, systemd's default of roughly 90s applies).

### Verifying the host

A few checks, as root.

Confirm nothing is in a failed state:

```
systemctl list-units --failed
```

Confirm rootless Docker answers as the runner user:

```
runuser -u gitlab-runner -- env "XDG_RUNTIME_DIR=/run/user/$(id -u gitlab-runner)" "DOCKER_HOST=unix:///run/user/$(id -u gitlab-runner)/docker.sock" docker info
```

That `runuser`/`env` shape is not optional decoration: the runner is a **no-login system user**,
so a plain `su`/`sudo -u` shell has no systemd user session, so `XDG_RUNTIME_DIR` and
`DOCKER_HOST` must point explicitly at its `/run/user/<uid>` tree to reach the rootless daemon (the module's
own healthcheck script wraps its checks in the same incantation).

Confirm every configured runner reaches GitLab with a valid token:

```
gitlab-runner verify
```

[`gitlab-runner verify`](https://docs.gitlab.com/runner/commands/#gitlab-runner-verify) asks
GitLab whether each registered runner can connect; run it by hand after rotating tokens. The
module's healthcheck timer does not run `verify`; it checks the manager service and the rootless
Docker daemon (as the runner user) on any standalone host, and — where the self-update loop is
enabled — also that the apply timer is still enabled and armed, checkout staleness against the
remote, and the bootstrap gems, surfacing failures as failed units. Token validity is the one
check you make manually.

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
2. Put the token into the secrets layer under a new `token_key`: on a standalone host
   [the secret store](docs/standalone.md#the-secret-store), in a fleet the server-side
   machinery (see [Secrets](#secrets)).
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
(authenticated by the current runner token itself). Then update the entry in the secrets layer
([The secret store](docs/standalone.md#the-secret-store) on a standalone host) and **apply
immediately**: the old
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
- <a id="ref-9"></a>\[9\] **Docker daemon attack surface**: why controlling the daemon (or its
  socket) is equivalent to root on the host.
  [Docker Docs](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)
- <a id="ref-10"></a>\[10\] **Subordinate UID/GID ranges**: the `/etc/subuid` and `/etc/subgid`
  allocations a user namespace maps. [subuid(5)](https://man7.org/linux/man-pages/man5/subuid.5.html)
- <a id="ref-11"></a>\[11\] **`newuidmap`/`newgidmap`**: setuid helpers that write a user
  namespace's UID/GID maps. [newuidmap(1)](https://man7.org/linux/man-pages/man1/newuidmap.1.html)
- <a id="ref-12"></a>\[12\] **Lingering**: `systemd-logind` keeping a user's manager running with
  no active login. [loginctl(1)](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html)
- <a id="ref-13"></a>\[13\] **cgroup v2**: the kernel's unified control-group hierarchy.
  [Kernel: Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)
- <a id="ref-14"></a>\[14\] **`overlay2`**: Docker's default OverlayFS storage driver.
  [Docker: OverlayFS storage driver](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
- <a id="ref-15"></a>\[15\] **`fuse-overlayfs`**: a FUSE OverlayFS implementation usable rootless on
  older kernels. [containers/fuse-overlayfs](https://github.com/containers/fuse-overlayfs)
- <a id="ref-16"></a>\[16\] **`DOCKER_HOST`**: the environment variable selecting the daemon socket
  the Docker client connects to. [Docker CLI: environment variables](https://docs.docker.com/reference/cli/docker/#environment-variables)
- <a id="ref-17"></a>\[17\] **`XDG_RUNTIME_DIR`**: the per-user runtime directory (`/run/user/<uid>`).
  [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/)
- <a id="ref-18"></a>\[18\] **GitLab Runner signals**: `SIGQUIT` requests a graceful shutdown —
  finish running jobs, then exit. [GitLab Runner: signals](https://docs.gitlab.com/runner/commands/#signals)
- <a id="ref-19"></a>\[19\] **`KillSignal`/`TimeoutStopSec`**: systemd's stop-signal and
  stop-timeout directives. [systemd.kill(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html)
- <a id="ref-20"></a>\[20\] **`DETACH_NETNS`**: RootlessKit's detached-network-namespace mode
  (NETNS = network namespace). [RootlessKit: detaching network namespace](https://github.com/rootless-containers/rootlesskit/blob/master/docs/network.md#detaching-network-namespace)
- <a id="ref-21"></a>\[21\] **Restricting job images**: the Docker executor's `allowed_images`.
  [GitLab Runner: restrict Docker images](https://docs.gitlab.com/runner/executors/docker/#restrict-docker-images-and-services)
- <a id="ref-22"></a>\[22\] **Network namespaces**: the kernel isolation giving a process group its
  own network devices, routing and firewall rules.
  [network_namespaces(7)](https://man7.org/linux/man-pages/man7/network_namespaces.7.html)
- <a id="ref-23"></a>\[23\] **BuildKit**: Docker's build backend; supports rootless, daemonless
  image builds. [Docker: BuildKit](https://docs.docker.com/build/buildkit/)
- <a id="ref-24"></a>\[24\] **D-Bus**: the message bus system; `dbus-user-session` provides its
  per-user session daemon, which `systemd --user` integration needs.
  [freedesktop.org: D-Bus](https://www.freedesktop.org/wiki/Software/dbus/)
- <a id="ref-25"></a>\[25\] **Docker Engine**: the containerization engine and daemon that runs
  the job containers. [Docker Engine](https://docs.docker.com/engine/)
- <a id="ref-26"></a>\[26\] **Docker CLI**: the `docker` command-line client.
  [Docker CLI reference](https://docs.docker.com/reference/cli/docker/)
- <a id="ref-27"></a>\[27\] **containerd**: the industry-standard container runtime the Docker
  daemon builds on. [containerd](https://containerd.io/)
