# @summary Declaratively manage a rootless GitLab Runner on a single host.
#
# Renders the runner config (config.toml) from a Hiera-driven list of runners,
# manages the rootless-docker "no-detach-netns" systemd user drop-in and the
# secret-store directory, installs the apt packages listed in `packages`, and
# optionally: owns the runner user, brings up the rootless docker user daemon
# (with the subordinate ID ranges it needs) behind a fail-loud
# preflight, manages the runner service together with its privilege-drop
# drop-in, and installs the standalone self-update units. Designed to run
# standalone via `puppet apply` with an isolated confdir/vardir so it never
# collides with a central Puppet agent.
#
# Runner tokens are never stored in this module or in version control. They
# are looked up at apply time from an off-repository secret store via the
# `runner_tokens` parameter, keyed by each runner's `token_key`.
#
# The `manage_*` parameters are persistent ownership switches, not one-shot
# bootstrap flags: set once per host and left on, so every apply keeps owning
# and drift-correcting that concern. `false` means hands-off, not ensure-off.
#
# @example Greenfield standalone host (everything on)
#   class { 'rootless_gitlab_runner':
#     packages              => ['uidmap', 'dbus-user-session', 'docker-ce',
#                               'docker-ce-cli', 'docker-ce-rootless-extras',
#                               'containerd.io', 'gitlab-runner'],
#     manage_apt_repos      => true,
#     runner_uid            => 2000,
#     manage_runner_user    => true,
#     manage_rootless_docker => true,
#     manage_runner_service => true,
#     runners               => [
#       { 'name'      => 'docker-rootless',
#         'url'       => 'https://gitlab.example.org/',
#         'executor'  => 'docker',
#         'image'     => 'ubuntu:22.04',
#         'token_key' => 'runner_a',
#       },
#     ],
#   }
#
# @param concurrent
#   Global `concurrent` value written to the runner config.
# @param runners
#   Ordered list of runner definitions. Each entry is a hash; recognised keys:
#   `name`, `url`, `id` (Integer), `executor`, `token_key`, `host`, `image`,
#   `privileged` (Boolean), `tls_verify` (Boolean), `socket_mount` (Boolean),
#   `volumes` (Array[String]), `security_opt` (Array[String]), `environment`
#   (Array[String]), `comment` (String), `helper_image` (String),
#   `disable_entrypoint_overwrite` (Boolean), `oom_kill_disable` (Boolean),
#   `disable_cache` (Boolean), `shm_size` (Integer), `network_mtu` (Integer),
#   `cache` (Hash — its presence renders the `[runners.cache]` tables; optional
#   key `MaxUploadedArchiveSize` (Integer, default 0)),
#   `allowed_images` (Array[String]), `allowed_pull_policies` (Array[String]).
#   Tokens are merged in from `runner_tokens[token_key]` and must not appear
#   here.
# @param runner_defaults
#   Hash merged under every `runners` entry (`$runner_defaults + $runner`,
#   keys set on the entry win), so multi-runner data does not repeat `url`,
#   `image`, `executor` and friends. Recognised keys as in `runners`.
# @param runner_tokens
#   `Sensitive` map of `token_key` => runner token, supplied by the
#   off-repository secret store. Typed `Sensitive` so the value is redacted in
#   the catalog and reports; the module ships `lookup_options`
#   (`convert_to: Sensitive`) so a plain-YAML or hiera-eyaml secret store is
#   wrapped automatically on lookup — consumers write ordinary Hiera data.
#   Empty by default so a checkout without secrets renders blank tokens. When
#   non-empty, every runner must carry a `token_key` that resolves here or the
#   apply fails (typo/missed-provisioning guard). The rendered configuration
#   content is `Sensitive` too, so tokens never reach the compiled catalog,
#   reports, or `--show_diff` output.
# @param runner_user
#   System user the runner manager and rootless docker run as.
# @param runner_uid
#   Numeric uid of the runner user. No default: the uid is host data, not
#   something a module can sensibly invent. It derives the rootless runtime
#   paths (`/run/user/<uid>`, the docker socket) and is enforced on the user
#   when `manage_runner_user` is on; the apply fails loud when it is unset but
#   needed — with `manage_runner_user`, `manage_rootless_docker` or
#   `manage_standalone_self_update` on, or to derive the docker socket path
#   for a `socket_mount` runner.
# @param runner_home
#   Home directory of the runner user.
# @param config_path
#   Path of the rendered runner config file. Owner and group derive from
#   `runner_user`; the mode is fixed 0600 (the file carries the runner
#   tokens).
# @param secret_store_path
#   Directory of the off-repo secret store. The directory itself is managed
#   (root-owned, 0700); the secret file inside it is host-provisioned and
#   never managed.
# @param packages
#   Packages to ensure installed. Empty list (the default) installs nothing.
#   The apt repositories serving them can be managed via `manage_apt_repos`;
#   with that off, repo setup is an external prerequisite.
# @param manage_apt_repos
#   Whether to manage the apt repositories the `packages` list installs from
#   (Docker's and GitLab Runner's, via `puppetlabs/apt`). Keep off where apt
#   sources are owned elsewhere (central config management, e.g. Foreman/Katello).
#   Default false.
# @param docker_repo_location
#   Docker apt repository URL (suite = OS codename, component `stable`).
# @param docker_repo_key_source
#   URL of Docker's armored signing key (stored as an apt keyring).
# @param gitlab_runner_repo_location
#   GitLab Runner apt repository URL (suite = OS codename, component `main`).
# @param gitlab_runner_repo_key_source
#   URL of GitLab Runner's armored signing key (stored as an apt keyring).
# @param manage_runner_user
#   Whether to manage the runner group, user, and home. Keep off where another
#   configuration-management system owns the user. The subordinate UID/GID
#   ranges rootless docker needs are owned by `manage_rootless_docker`.
#   Default false.
# @param subid_start
#   First subordinate UID/GID allocated to the runner user (written by
#   `manage_rootless_docker`).
# @param subid_count
#   Number of subordinate UIDs/GIDs allocated (rootless docker needs at
#   least 65536). The 165536 default fits nested rootless BuildKit builds:
#   the rootless BuildKit image maps IDs 100000-165535 inside the build
#   container.
# @param manage_rootless_docker
#   Whether to bring up the rootless docker user daemon: provision the
#   subordinate UID/GID ranges (`subid_start`/`subid_count`; an existing entry
#   is never overwritten, and the runner user may be owned elsewhere), enable
#   lingering and run `dockerd-rootless-setuptool.sh install` (guarded, as the
#   runner user), behind a fail-loud preflight that asserts the prerequisites
#   instead of half-installing. Also stops and masks the rootful system
#   `docker.service`/`docker.socket`, which a fresh `docker-ce` install starts
#   as root, so the only Docker daemon on the host is the unprivileged one.
#   cgroup-v2 controller delegation is deliberately not managed
#   (it would be the module's only system-wide write); without it CPU/IO job
#   limits are silently unenforced — see the README Limitations. Default false.
# @param manage_runner_service
#   Whether to manage the runner system service, its privilege-drop systemd
#   drop-in, and the config directory's mode so a privilege-dropped manager can
#   traverse to its config. The manager always runs privilege-dropped as
#   `runner_user`. Default false.
# @param service_environment
#   Environment lines (KEY=value) rendered into the service drop-in. When
#   unset, defaults to pointing DOCKER_HOST at the rootless docker socket. Each
#   line must be a single line — a value containing a newline is rejected, so it
#   cannot inject an extra systemd directive into the drop-in.
# @param service_timeout_stop_sec
#   `TimeoutStopSec=` written into the manager service drop-in — how long
#   systemd waits for a graceful drain before escalating to `SIGKILL`. Unset by
#   default, so systemd's `DefaultTimeoutStopSec` (typically 90s) applies; set
#   it to the longest job a drain should wait for (GitLab's documented example
#   is `7200`). Accepts a seconds integer or a systemd time span (e.g. `2h`).
# @param manage_standalone_self_update
#   Whether to install the standalone self-update loop: an apply script, a
#   oneshot service + timer that fetch the control repo, verify the commit
#   signature, reset to the remote branch, run `r10k puppetfile install` and
#   re-apply — plus a healthcheck script + timer (manager service, rootless
#   docker daemon health as the runner user, checkout SHA staleness). Never
#   enable this where a Puppet server/r10k already deploys the host. Default
#   false.
# @param repo_path
#   Root-owned checkout of the control repository the self-update loop
#   applies. The apply's manifest, module directory and Hiera configuration
#   derive strictly from the documented layout beneath it
#   (`puppet/manifests/site.pp`, `puppet/modules`, `puppet/hiera.yaml`).
# @param repo_branch
#   Branch the self-update loop follows (protected, signed).
# @param apply_confdir
#   Isolated Puppet confdir for the apply (never the central agent's).
# @param apply_vardir
#   Isolated Puppet vardir for the apply (never the central agent's).
# @param apply_interval
#   systemd time span between self-update runs.
# @param apply_timeout
#   TimeoutStartSec of the apply service (a oneshot unit has no default start
#   timeout).
# @param puppet_bindir
#   Directory holding the `puppet` (and typically `r10k`) executables,
#   prepended to the self-update service's PATH so the timer-driven,
#   non-login apply can find them. Override for a non-standard install.
# @param healthcheck_interval
#   systemd time span between healthcheck runs.
class rootless_gitlab_runner (
  Integer[1]               $concurrent             = 1,
  Array[Hash]              $runners                = [],
  Hash                     $runner_defaults        = {},
  Sensitive[Hash[String, String]] $runner_tokens   = Sensitive({}),
  Rootless_gitlab_runner::Username $runner_user    = 'gitlab-runner',
  Optional[Integer[1]]     $runner_uid             = undef,
  Stdlib::Absolutepath     $runner_home            = '/home/gitlab-runner',
  Stdlib::Absolutepath     $config_path            = '/etc/gitlab-runner/config.toml',
  Stdlib::Absolutepath     $secret_store_path      = '/etc/gitlab-runner-infra',
  Array[String[1]]         $packages               = [],
  Boolean                  $manage_apt_repos       = false,
  Stdlib::HTTPUrl          $docker_repo_location   = 'https://download.docker.com/linux/ubuntu',
  Stdlib::HTTPUrl          $docker_repo_key_source = 'https://download.docker.com/linux/ubuntu/gpg',
  Stdlib::HTTPUrl          $gitlab_runner_repo_location = 'https://packages.gitlab.com/runner/gitlab-runner/ubuntu',
  Stdlib::HTTPUrl          $gitlab_runner_repo_key_source = 'https://packages.gitlab.com/runner/gitlab-runner/gpgkey',
  Boolean                  $manage_runner_user     = false,
  Integer[1]               $subid_start            = 231072,
  Integer[65536]           $subid_count            = 165536,
  Boolean                  $manage_rootless_docker = false,
  Boolean                  $manage_runner_service  = false,
  Optional[Array[Pattern[/\A[^\r\n]+\z/]]] $service_environment = undef,
  Optional[Variant[Integer[0], String[1]]] $service_timeout_stop_sec = undef,
  Boolean                  $manage_standalone_self_update = false,
  Stdlib::Absolutepath     $repo_path              = '/opt/gitlab-runner-infra',
  String[1]                $repo_branch            = 'main',
  Stdlib::Absolutepath     $apply_confdir          = '/etc/gitlab-runner-infra/puppet',
  Stdlib::Absolutepath     $apply_vardir           = '/var/lib/grunner-puppet',
  String[1]                $apply_interval         = '5min',
  String[1]                $apply_timeout          = '15min',
  Stdlib::Absolutepath     $puppet_bindir          = '/opt/puppetlabs/bin',
  String[1]                $healthcheck_interval   = '15min',
) {

  # The uid is host data with no sensible module default. Fail loud where it
  # is needed but unset, instead of inventing one. The self-update loop needs
  # it too: its healthcheck probes the rootless daemon as the runner user.
  if $runner_uid =~ Undef and ($manage_runner_user or $manage_rootless_docker or $manage_standalone_self_update) {
    fail(join([
      'rootless_gitlab_runner: runner_uid must be set when manage_runner_user, ',
      'manage_rootless_docker or manage_standalone_self_update is enabled',
    ]))
  }

  # Defaults merged under every runner entry; keys set on the entry win.
  $effective_runners = $runners.map |$r| { $runner_defaults + $r }

  # Rootless runtime paths derived from the uid where known: the module
  # itself installs the daemon socket at /run/user/<uid>/docker.sock, so the
  # path is derivation, not configuration. An exotic external socket is
  # expressible via service_environment.
  if $runner_uid =~ Integer {
    $runtime_dir = "/run/user/${runner_uid}"
    $socket_path = "${runtime_dir}/docker.sock"
  } else {
    $runtime_dir = undef
    $socket_path = undef
  }

  # Environment contract for every exec run as the runner user: non-interactive
  # root Puppet provides neither XDG_RUNTIME_DIR nor DBUS_SESSION_BUS_ADDRESS,
  # and systemctl --user / the setuptool fail without them.
  $runner_user_env = [
    "HOME=${runner_home}",
    "USER=${runner_user}",
    "XDG_RUNTIME_DIR=${runtime_dir}",
    "DBUS_SESSION_BUS_ADDRESS=unix:path=${runtime_dir}/bus",
  ]

  if $manage_runner_service and $socket_path =~ Undef and $service_environment =~ Undef {
    fail(join([
      'rootless_gitlab_runner: the privilege-dropped runner service needs DOCKER_HOST — ',
      'set runner_uid or service_environment',
    ]))
  }

  $real_service_environment = $service_environment ? {
    undef   => $socket_path ? {
      undef   => [],
      default => ["DOCKER_HOST=unix://${socket_path}"],
    },
    default => $service_environment,
  }

  contain rootless_gitlab_runner::apt_repos
  contain rootless_gitlab_runner::packages
  contain rootless_gitlab_runner::user
  contain rootless_gitlab_runner::rootless_docker
  contain rootless_gitlab_runner::config
  contain rootless_gitlab_runner::service
  contain rootless_gitlab_runner::self_update

  # One-shot fresh apply must converge in order: packages first, then the
  # user, then daemon bring-up (subids, then the preflight that asserts what
  # the earlier steps establish), then config + drop-ins, then the service.
  # Classes whose toggle is off are empty and drop out of the chain.
  Class['rootless_gitlab_runner::apt_repos']
  -> Class['rootless_gitlab_runner::packages']
  -> Class['rootless_gitlab_runner::user']
  -> Class['rootless_gitlab_runner::rootless_docker']
  -> Class['rootless_gitlab_runner::config']
  -> Class['rootless_gitlab_runner::service']
  -> Class['rootless_gitlab_runner::self_update']
}
