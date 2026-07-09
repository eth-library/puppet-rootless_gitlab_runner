# Changelog

All notable, consumer-facing changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
module follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-07-09

The initial release: a rootless GitLab Runner host — runner config, the rootless-Docker pieces it depends on, packages, and secrets — managed as reviewable Puppet code, applied standalone or from a Puppet fleet. Targets Ubuntu 22.04 with Puppet 8/OpenVox 8.

### Added

#### Runner configuration
- Manage the entire GitLab Runner `config.toml` file from Hiera data — global settings and any number of runners on a single host, all from one node file. The module is never edited to onboard a host or team; host data drives it.
- Declare values shared by every runner once (`url`, `image`, `executor`, …) and override per runner where needed.
- Support the Docker executor options runners actually use — images, volumes, environment, per-runner caching, and image/pull-policy allowlists — so the module stays out of the way of runner tuning.
- Changes converge continuously: once a data change is applied, the runner adopts the new configuration on its own within seconds — no service restarts to arrange.
- Removing a runner is a data change too: drop its entry from Hiera and the next apply renders it out of the config, so the host stops offering it (delete the record on the GitLab side separately).

#### Rootless Docker
- Make the rootless-Docker `no-detach-netns` fix permanent, so routine package upgrades on Ubuntu 22.04 stop silently breaking rootless container networking.
- A toggle lets the module build the runner user's rootless Docker daemon from scratch — so a fresh host becomes a working runner from the module alone — or, left off, treats an existing daemon as a prerequisite. When it builds the daemon, a preflight checks the prerequisites first and stops with a clear message if any is missing.

#### Secrets
- Keep runner tokens out of git: they live in an off-repository store on the host and are referenced by name, so neither the control repository nor the rendered configuration ever contains a secret.
- Deploy pre-created GitLab runner tokens — the module never talks to the GitLab API, so an apply never depends on GitLab being reachable, and a host only ever holds its own runner token.
- Fail loudly on an unrecognized runner setting, and — when a secret store is present — on any runner whose token can't be resolved, so a typo (even in a security allowlist) stops the apply instead of silently bringing up a misconfigured runner. Without a store (dry-runs, CI validation), tokens render blank by design, so the configuration still compiles anywhere.

#### Flexible host ownership
- Opt-in toggles decide what the module owns on each host: the runner user and the rootless prerequisites it needs, the Docker and GitLab Runner apt repositories (so stock Ubuntu just works), the package set, and the runner service itself.
- Any toggle left off keeps the module hands-off that concern — safe to run alongside another configuration-management system that already owns the user, the daemon, or the repositories.
- Coexist with a central Puppet agent: the standalone apply runs with an isolated `--confdir`/`--vardir`, so it never collides with an existing agent's configuration or state on the same host.
- Restart the runner gracefully: where the module owns the service, a restart drains running jobs (SIGQUIT) instead of aborting them, tunable via a kill-signal and a stop-timeout, so a legitimate restart never kills in-flight CI jobs.

#### Standalone self-update
- A single toggle turns a host into a self-converging runner: the module installs a timer that pulls the control repository, verifies it, and re-applies on a schedule, so drift corrects itself while every change stays review-gated through git.
- Only signed commits on the protected branch are ever applied.
- A built-in health check continuously confirms the runner is healthy and the host has not fallen behind on a stale checkout, surfacing problems through ordinary host monitoring. It also verifies the apply timer is still enabled, so a halted self-update is caught at once.
- Route failures to your own alerting: an optional hook fires a systemd unit of your choice when an apply or healthcheck run fails.

### Security
- Rootless by design: the runner and its Docker daemon run as an unprivileged user, not root; where the module manages the runner service, it runs privilege-dropped by default.
- With the rootless bring-up enabled, the module stops and masks the rootful system Docker daemon and the idle root containerd service that installing `docker-ce`/`containerd.io` otherwise leaves running as root, so the only container daemon on the host is the unprivileged one.
- Runner tokens are handled as sensitive values end to end, so they stay out of compiled catalogs, Puppet reports, and configuration diffs.
- Config inputs are escaped and type-checked where they are rendered, so a stray quote, newline or malformed value in host data is escaped or rejected up front instead of producing a broken or injected runner configuration.

[Unreleased]: https://github.com/eth-library/puppet-rootless_gitlab_runner/compare/v1.0.0...main
[1.0.0]: https://github.com/eth-library/puppet-rootless_gitlab_runner/releases/tag/v1.0.0
