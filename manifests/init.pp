# @summary Declaratively manage a rootless GitLab Runner on a single host.
#
# Renders the runner configuration file (config.toml) from a Hiera-driven list
# of runners, manages the rootless-docker "no-detach-netns" systemd user
# drop-in and the secret-store directory, installs the apt packages listed in
# `packages.install`, and optionally: owns the runner account, brings up the
# rootless docker user daemon (with the subordinate ID ranges it needs) behind
# a fail-loud preflight, manages the runner service together with its
# privilege-drop drop-in, and installs the standalone apply script with the
# optional self-update loop. Designed to run standalone via `puppet apply`
# with an isolated confdir/vardir so it never collides with a central Puppet
# agent.
#
# Runner tokens are never stored in this module or in version control. They
# are looked up at apply time from an off-repository secret store via the
# `runner_tokens` parameter, keyed by each runner's `token_key`.
#
# Every parameter default lives in the module data layer (`data/common.yaml`),
# and each struct parameter carries a deep-merge lookup rule, so consumer data
# holds only deviations: a partial hash is merged over the module defaults on
# lookup. The documented consumption pattern is Hiera plus
# `include rootless_gitlab_runner`; a resource-style declaration bypasses
# Hiera merging and must pass complete struct hashes.
#
# The `manage` keys are persistent ownership switches, not one-shot bootstrap
# flags: set once per host and left on, so every apply keeps owning and
# drift-correcting that concern. `false` means hands-off, not ensure-off. A
# `manage` key decides whether the module creates and enforces its concern's
# resources; most struct keys are consumed only by their own concern (so they
# are inert while its `manage` is false), while `runner_account`'s identity
# keys are shared inputs every concern reads.
#
# @example Greenfield standalone host (everything on), as Hiera node data
#   rootless_gitlab_runner::runners:
#     - name: 'docker-rootless'
#       url: 'https://gitlab.example.org/'
#       executor: 'docker'
#       image: 'ubuntu:22.04'
#       token_key: 'runner_a'
#   rootless_gitlab_runner::runner_account:
#     manage: true
#     uid: 2000
#   rootless_gitlab_runner::packages:
#     install: ['uidmap', 'dbus-user-session', 'docker-ce', 'docker-ce-cli',
#               'docker-ce-rootless-extras', 'containerd.io', 'gitlab-runner']
#     sources:
#       manage: true
#   rootless_gitlab_runner::rootless_docker:
#     manage: true
#   rootless_gitlab_runner::runner_service:
#     manage: true
#   rootless_gitlab_runner::standalone:
#     manage: true
#
# @param concurrent
#   Global `concurrent` value written to the runner configuration file: the
#   name is GitLab Runner's own `config.toml` global key, written unchanged.
#   Default 1.
# @param runners
#   Ordered list of runner definitions, rendered as the `[[runners]]` sections
#   of `config.toml`. Each entry is a hash; recognised keys:
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
#   here. `host` is only for an externally managed daemon at a non-derived
#   path: where the module manages the runner service, the drop-in's
#   `DOCKER_HOST` already points the executor at the derived rootless socket.
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
# @param secret_store_path
#   Path of the off-repository secret store directory. The directory itself is
#   managed (root-owned, 0700); the secret file inside it is host-provisioned
#   and never managed. Default `/etc/gitlab-runner-infra`.
# @param configuration_file
#   The rendered runner configuration file (GitLab Runner's `config.toml`).
#   Owner derives from `runner_account.name` and group from
#   `runner_account.group` (which defaults to the name); the mode is fixed 0600
#   (the file carries the runner tokens).
# @option configuration_file [Stdlib::Absolutepath] :path
#   Where the file is written. Default `/etc/gitlab-runner/config.toml`.
# @param runner_account
#   The OS account the runner manager and the rootless docker daemon run as.
#   The identity keys are read by every concern even when `manage: false`
#   (socket derivation, file ownership, service `ExecStart`); the toggle only
#   decides whether the module creates and enforces the group, user, and home.
# @option runner_account [Boolean] :manage
#   Whether to manage the runner group, user, and home. Keep off where another
#   configuration-management system owns the account. The subordinate UID/GID
#   ranges rootless docker needs are owned by `rootless_docker.manage`.
#   Default false.
# @option runner_account [Rootless_gitlab_runner::Username] :name
#   Username of the runner account. Default `gitlab-runner`.
# @option runner_account [Optional[Rootless_gitlab_runner::Username]] :group
#   Name of the account's primary group. Defaults to the account name (the
#   data layer cannot express that default, so an unset key falls back to
#   `name` in code). Set it for an externally provisioned account whose primary
#   group is named differently (account `ci-worker`, group `ci`): it feeds
#   every group ownership the module manages — the group resource and the
#   user's primary group where `manage` is on, and the group of the runner
#   configuration file, its directory, and the account's systemd user tree.
# @option runner_account [Optional[Integer[1]]] :uid
#   Numeric uid of the runner account. No default: the uid is host data, not
#   something a module can sensibly invent. It derives the rootless runtime
#   paths (`/run/user/<uid>`, the docker socket) and is enforced on the user
#   when `runner_account.manage` is on; the apply fails loud when it is unset
#   but needed — with `runner_account.manage`, `rootless_docker.manage` or
#   `standalone.self_update.manage` on, or to derive the docker socket path
#   for a `socket_mount` runner.
# @option runner_account [Stdlib::Absolutepath] :home
#   Home directory of the runner account. Default `/home/gitlab-runner`.
# @param packages
#   The apt-packages concern: what to install, and the apt sources serving it.
# @option packages [Array[String[1]]] :install
#   Packages to ensure installed. The empty default installs nothing. Install
#   only: the module never removes packages absent from the list and never
#   pins or upgrades.
# @option packages [Hash] :sources
#   The apt sources the `install` list installs from (Docker's and GitLab
#   Runner's, via `puppetlabs/apt`). `sources.manage` (default false) decides
#   ownership: keep it off where apt sources are owned elsewhere (central
#   configuration management, e.g. Foreman/Katello, or a mirror). The
#   `docker` and `gitlab_runner` sub-hashes each carry `location` and
#   `key_source` — verbatim `apt::source` parameter names — overridden only
#   for a mirror; the defaults point at the vendors' repositories and their
#   rolling signing-key endpoints.
# @param rootless_docker
#   The rootless docker runtime: "rootless mode" is Docker's own name for
#   running the daemon unprivileged.
# @option rootless_docker [Boolean] :manage
#   Whether to bring up the rootless docker user daemon: provision the
#   subordinate UID/GID ranges (an existing entry is never overwritten, and
#   the runner account may be owned elsewhere), enable lingering and run
#   `dockerd-rootless-setuptool.sh install` (guarded, as the runner user),
#   behind a fail-loud preflight that asserts the prerequisites instead of
#   half-installing. Also stops and masks the rootful system
#   `docker.service`/`docker.socket` and `containerd.service`, which a fresh
#   `docker-ce` install starts as root, so the only Docker daemon on the host
#   is the unprivileged one. cgroup-v2 controller delegation is deliberately
#   not managed (it would be the module's only system-wide write); without it
#   CPU/IO job limits are silently unenforced — see the README Limitations.
#   Default false.
# @option rootless_docker [Integer[1]] :subid_start
#   First subordinate UID/GID allocated to the runner account (field two of
#   the `/etc/subuid` entry format, per `subid(5)`). Default 231072.
# @option rootless_docker [Integer[65536]] :subid_count
#   Number of subordinate UIDs/GIDs allocated (field three of the entry;
#   rootless docker needs at least 65536). Default 165536, which also covers
#   BuildKit's rootless image layout.
# @param runner_service
#   The systemd system service running the runner manager, privilege-dropped
#   to the runner account.
# @option runner_service [Boolean] :manage
#   Whether to manage the runner system service, its privilege-drop systemd
#   drop-in, and the configuration directory's mode so a privilege-dropped
#   manager can traverse to its configuration file. Default false.
# @option runner_service [Optional[Array[String]]] :environment
#   `Environment=` lines (KEY=value) rendered into the service drop-in. When
#   unset, defaults to pointing DOCKER_HOST at the rootless docker socket
#   derived from `runner_account.uid`. Each line must be a single line — a
#   value containing a newline is rejected, so it cannot inject an extra
#   systemd directive into the drop-in.
# @option runner_service [Optional[Variant[Integer[0], String[1]]]] :timeout_stop_sec
#   `TimeoutStopSec=` written into the manager service drop-in — how long
#   systemd waits for a graceful drain before escalating to `SIGKILL`. Unset
#   by default, so systemd's `DefaultTimeoutStopSec` (typically 90s) applies;
#   set it to the longest job a drain should wait for (GitLab's documented
#   example is `7200`). Accepts a seconds integer or a systemd time span
#   (e.g. `2h`).
# @param standalone
#   The standalone topology: a host that applies itself via `puppet apply`,
#   as opposed to a fleet host deployed by a Puppet server — with the
#   optional self-update loop nested inside.
# @option standalone [Boolean] :manage
#   Declares the host standalone: installs the apply script
#   (`/usr/local/sbin/rootless-gitlab-runner-apply`), the single definition
#   of the apply command for timer-driven and manual runs. Default false.
# @option standalone [Stdlib::Absolutepath] :control_repository_path
#   Root-owned checkout of the control repository on the host (the apply and
#   self-update target). The apply's manifest, module directory and Hiera
#   configuration derive strictly from the documented layout beneath it
#   (`puppet/manifests/site.pp`, `puppet/modules`, `puppet/hiera.yaml`).
#   Default `/opt/gitlab-runner-infra`.
# @option standalone [String[1]] :control_repository_branch
#   Branch the self-update loop follows (protected, signed). Default `main`.
# @option standalone [Stdlib::Absolutepath] :puppet_confdir
#   Isolated Puppet confdir for the apply — never the central agent's.
#   Default `/etc/gitlab-runner-infra/puppet`.
# @option standalone [Stdlib::Absolutepath] :puppet_vardir
#   Isolated Puppet vardir for the apply — never the central agent's.
#   Default `/var/lib/grunner-puppet`.
# @option standalone [Stdlib::Absolutepath] :puppet_bindir
#   Directory holding the `puppet` (and typically `r10k`) executables,
#   prepended to the self-update service's PATH so the timer-driven,
#   non-login apply can find them. Default `/opt/puppetlabs/bin`; the
#   AIO-reuse topology sets `/opt/puppetlabs/puppet/bin` (gem executables
#   live there, not in the symlink farm).
# @option standalone [String[1]] :healthcheck_interval
#   systemd time span between healthcheck runs. Default `15min`.
# @option standalone [Hash] :self_update
#   The self-update loop: `manage` (default false) installs a oneshot
#   service + timer that fetch the control repository, verify the commit
#   signature, reset to the remote branch, run `r10k puppetfile install` and
#   re-apply — plus the healthcheck script + timer. Only valid on a
#   standalone host: enabling it with `standalone.manage` off fails at
#   compile time. Never enable it where a Puppet server or r10k already
#   deploys the host. `apply_interval` (default `5min`) is the timer's
#   cadence; `apply_timeout` (default `15min`) the apply service's
#   `TimeoutStartSec=` (a oneshot unit has no default start timeout).
class rootless_gitlab_runner (
  Integer[1]                       $concurrent,
  Array[Hash]                      $runners,
  Hash                             $runner_defaults,
  Sensitive[Hash[String, String]]  $runner_tokens,
  Stdlib::Absolutepath             $secret_store_path,
  Struct[{
    path => Stdlib::Absolutepath,
  }]                               $configuration_file,
  Struct[{
    manage => Boolean,
    name   => Rootless_gitlab_runner::Username,
    group  => Optional[Rootless_gitlab_runner::Username],
    uid    => Optional[Integer[1]],
    home   => Stdlib::Absolutepath,
  }]                               $runner_account,
  Struct[{
    install => Array[String[1]],
    sources => Struct[{
      manage        => Boolean,
      docker        => Struct[{
        location   => Stdlib::HTTPUrl,
        key_source => Stdlib::HTTPUrl,
      }],
      gitlab_runner => Struct[{
        location   => Stdlib::HTTPUrl,
        key_source => Stdlib::HTTPUrl,
      }],
    }],
  }]                               $packages,
  Struct[{
    manage      => Boolean,
    subid_start => Integer[1],
    subid_count => Integer[65536],
  }]                               $rootless_docker,
  Struct[{
    manage           => Boolean,
    environment      => Optional[Array[Pattern[/\A[^\r\n]+\z/]]],
    timeout_stop_sec => Optional[Variant[Integer[0], String[1]]],
  }]                               $runner_service,
  Struct[{
    manage                    => Boolean,
    control_repository_path   => Stdlib::Absolutepath,
    control_repository_branch => String[1],
    puppet_confdir            => Stdlib::Absolutepath,
    puppet_vardir             => Stdlib::Absolutepath,
    puppet_bindir             => Stdlib::Absolutepath,
    healthcheck_interval      => String[1],
    self_update               => Struct[{
      manage         => Boolean,
      apply_interval => String[1],
      apply_timeout  => String[1],
    }],
  }]                               $standalone,
) {

  # Containment is enforced, not just documented: the self-update loop only
  # exists on a standalone host, and the hierarchy expresses that.
  if $standalone['self_update']['manage'] and !$standalone['manage'] {
    fail(join([
      'rootless_gitlab_runner: standalone.self_update.manage requires ',
      'standalone.manage — the self-update loop only runs on a standalone host',
    ]))
  }

  # The uid is host data with no sensible module default. Fail loud where it
  # is needed but unset, instead of inventing one. The self-update loop needs
  # it too: its healthcheck probes the rootless daemon as the runner user.
  if $runner_account['uid'] =~ Undef and ($runner_account['manage'] or $rootless_docker['manage'] or $standalone['self_update']['manage']) {
    fail(join([
      'rootless_gitlab_runner: runner_account.uid must be set when runner_account.manage, ',
      'rootless_docker.manage or standalone.self_update.manage is enabled',
    ]))
  }

  # The account's primary group, derived once and read as a group by every
  # concern (the group resource and the user's gid in user.pp, and every
  # managed file's group in config.pp). The data layer cannot express "same as
  # the account name", so the default is an absent key and the fallback lives
  # here: an unset group follows the account name — correct by construction
  # where the module creates the account — while a set group names the
  # differently named primary group of an externally provisioned account.
  $runner_group = pick($runner_account['group'], $runner_account['name'])

  # Defaults merged under every runner entry; keys set on the entry win.
  $effective_runners = $runners.map |$r| { $runner_defaults + $r }

  # Rootless runtime paths derived from the uid where known: the module
  # itself installs the daemon socket at /run/user/<uid>/docker.sock, so the
  # path is derivation, not configuration. An exotic external socket is
  # expressible via runner_service.environment.
  if $runner_account['uid'] =~ Integer {
    $runtime_dir = "/run/user/${runner_account['uid']}"
    $socket_path = "${runtime_dir}/docker.sock"
  } else {
    $runtime_dir = undef
    $socket_path = undef
  }

  # Environment contract for every exec run as the runner user: non-interactive
  # root Puppet provides neither XDG_RUNTIME_DIR nor DBUS_SESSION_BUS_ADDRESS,
  # and systemctl --user / the setuptool fail without them.
  $runner_user_env = [
    "HOME=${runner_account['home']}",
    "USER=${runner_account['name']}",
    "XDG_RUNTIME_DIR=${runtime_dir}",
    "DBUS_SESSION_BUS_ADDRESS=unix:path=${runtime_dir}/bus",
  ]

  if $runner_service['manage'] and $socket_path =~ Undef and $runner_service['environment'] =~ Undef {
    fail(join([
      'rootless_gitlab_runner: the privilege-dropped runner service needs DOCKER_HOST — ',
      'set runner_account.uid or runner_service.environment',
    ]))
  }

  $real_service_environment = $runner_service['environment'] ? {
    undef   => $socket_path ? {
      undef   => [],
      default => ["DOCKER_HOST=unix://${socket_path}"],
    },
    default => $runner_service['environment'],
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
