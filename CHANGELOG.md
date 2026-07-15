# Changelog

All notable, consumer-facing changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
module follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Subordinate UID/GID ranges are now provisioned by `manage_rootless_docker`, together with the other rootless-Docker prerequisites, instead of by `manage_runner_user`: rootless Docker can now be brought up on a host whose runner user is owned by another system. An existing range entry is never overwritten, and `manage_runner_user` keeps owning the group, user, and home.

## [1.0.0] - 2026-07-09

The initial release: a rootless GitLab Runner host — runner config, the rootless-Docker pieces it depends on, packages, and secrets — managed as reviewable Puppet code, applied standalone or from a Puppet fleet. Targets Ubuntu 22.04 with Puppet 8/OpenVox 8.

### Added

#### Runner configuration
- Manage the entire GitLab Runner `config.toml` from Hiera data — global settings and any number of runners on a single host, all from one node file.
- Declare values shared by every runner once (`url`, `image`, `executor`, …) and override per runner where needed.
- Support the Docker executor options runners actually use — images, volumes, environment, per-runner caching, and image/pull-policy allowlists.
- A config change needs no service restart — GitLab Runner re-reads `config.toml` within seconds on its own.
- Remove a runner as a data change: drop its entry from Hiera and the next apply renders it out.

#### Rootless Docker
- Make the rootless-Docker `no-detach-netns` fix permanent, so package upgrades on Ubuntu 22.04 stop breaking rootless container networking.
- Optionally build the runner user's rootless Docker daemon from scratch, with a preflight check on prerequisites; or, left off, treat an existing daemon as a prerequisite.

#### Secrets
- Fetch runner tokens by name from an off-repository store on the host, so neither the control repository nor the rendered configuration contains a secret.
- The module consumes pre-created runner tokens and never calls the GitLab API, so an apply never depends on GitLab being reachable.
- Fail loudly on an unrecognized runner setting, or a token that can't be resolved when a secret store is present. Without a store, tokens render blank so the configuration still compiles.

#### Flexible host ownership
- Opt-in toggles decide what the module owns per host: the runner user and its rootless prerequisites, the Docker and GitLab Runner apt repositories, the package set, and the runner service.
- Any toggle left off keeps the module hands-off that concern, so it is safe to run alongside another configuration-management system.
- Coexist with a central Puppet agent: the standalone apply runs with an isolated `--confdir`/`--vardir`, so it never collides with an existing agent.
- Restart the runner gracefully: a restart drains running jobs (SIGQUIT) instead of aborting them, tunable via a kill-signal and stop-timeout.

#### Standalone self-update
- A single toggle turns a host into a self-converging runner: a timer pulls the control repository, verifies it, and re-applies on a schedule, so drift corrects itself while every change stays review-gated through git.
- Only signed commits on the protected branch are ever applied.
- A built-in health check confirms the runner is healthy, the checkout is not stale, and the apply timer is still enabled, surfacing problems through ordinary host monitoring.
- Route failures to your own alerting: an optional hook fires a systemd unit when an apply or healthcheck run fails.

### Security
- Rootless by design: the runner and its Docker daemon run as an unprivileged user, and the runner service runs privilege-dropped by default.
- With rootless bring-up enabled, the module stops and masks the rootful system Docker daemon and the idle root containerd service, so the only container daemon on the host is the unprivileged one.
- Runner tokens are handled as sensitive values end to end, so they stay out of compiled catalogs, Puppet reports, and configuration diffs.
- Config inputs are escaped and type-checked where they are rendered, so a malformed value in host data is rejected up front instead of producing a broken or injected configuration.

[Unreleased]: https://github.com/eth-library/puppet-rootless_gitlab_runner/compare/v1.0.0...main
[1.0.0]: https://github.com/eth-library/puppet-rootless_gitlab_runner/releases/tag/v1.0.0
