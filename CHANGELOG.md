# Changelog

All notable, consumer-facing changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
module follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An externally provisioned runner account whose primary group is named differently from the account now converges on the first apply: the new optional `runner_account.group` names the account's primary group and feeds every group ownership the module manages. It defaults to the account name, so existing hosts are unchanged.
- A Hiera data check ships with the module: it fails on any data key that no deployed class declares, instead of Hiera silently ignoring it, and flags subkeys set under a disabled `manage` toggle with a non-failing advisory.

### Changed

- The parameter surface is regrouped: five flat keys plus six parameter groups replace the 49 flat parameters. Related settings now live together, one hash per concern: `runner_account`, `configuration_file`, `packages` with its apt `sources`, `rootless_docker`, `runner_service`, and `standalone` with the nested `self_update`.
- Every subkey ships a module default and the groups merge deep across Hiera layers, so node data holds only its deviations, and a mistyped subkey now fails the compile instead of being silently ignored.
- The runner-token store reads as part of the runner family: `tokens` is now `runner_tokens`, alongside `runners` and `runner_defaults`. The automatic `Sensitive` wrap on lookup moves with the new key; the host's secret store file must follow the rename.
- The apply script now installs on any declared-standalone host (`standalone.manage: true`), not only with the self-update loop, so manual applies and the loop share the same single apply command; enabling the loop on a host not declared standalone fails at compile time.
- Freshly provisioned hosts now get a 165536-wide subordinate-ID range, which satisfies the ID-mapping requirement of nested rootless BuildKit builds.
- Subordinate UID/GID ranges are now provisioned by `rootless_docker.manage`, together with the other rootless-Docker prerequisites, instead of by the runner-account toggle: rootless Docker can now be brought up on a host whose runner account is owned by another system. An existing range entry is never overwritten, and `runner_account.manage` keeps owning the group, user, and home.
- The managed runner service's `DOCKER_HOST` is now module-owned and derived from `runner_account.uid`; `runner_service.environment` carries additional variables only and rejects a `DOCKER_HOST` line, and a managed service requires `runner_account.uid`.

### Removed

- Every parameter the module can derive is now automatic: the rendered configuration's owner and group follow `runner_account.name` (which also fixes the file staying owned by the default account name when a different account is declared), the docker socket path follows `runner_account.uid`, the no-detach-netns drop-in location follows `runner_account.home`, and the apply's manifest, module directory and Hiera configuration follow the documented control-repository layout under `standalone.control_repository_path`. `service_user` goes with them: the runner manager service always runs privilege-dropped as the runner account.
- Deliberate choices are no longer parameters: `runner_binary`, `service_name` and `setuptool_path` take the values their packages define, `service_kill_signal` is always `SIGQUIT` (the graceful drain), and `config_mode` and `dropin_mode` keep their former defaults.
- `check_interval`, `connection_max_age` and `shutdown_timeout` are no longer rendered. The removed lines matched GitLab Runner's own defaults, so existing hosts behave the same.
- `on_failure_unit` is removed; a push alert attaches as a host-side `OnFailure=` drop-in on the apply or healthcheck service.

### Fixed

- Clearing `runner_service.environment` through data can no longer leave the runner manager without `DOCKER_HOST`; the derived socket is always present.
- With `packages.sources.manage` on, repeated applies stop churning apt: an unchanged repository signing key is now a true no-op (no keyring rewrite, no needless `apt-get update`), while a genuine key rotation is still picked up from the vendor's rolling key endpoint and refreshes the apt index.

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
