# @summary Renders the runner config, the no-detach-netns drop-in and the secret-store directory.
# @api private
class rootless_gitlab_runner::config {
  assert_private()

  $socket_path = $rootless_gitlab_runner::socket_path
  $socket_mount_runners = $rootless_gitlab_runner::effective_runners.filter |$r| { $r['socket_mount'] == true }

  if $socket_path =~ Undef and !$socket_mount_runners.empty {
    fail('rootless_gitlab_runner: a runner sets socket_mount but the socket path is unknown — set runner_uid or docker_socket_path')
  }

  # Recognised per-runner keys. An unrecognised key is almost always a typo,
  # and silently dropping it can quietly remove a security control (a mistyped
  # allowed_images leaves the allowlist off). Fail loud instead of vanishing it.
  $recognised_runner_keys = [
    'name', 'url', 'id', 'executor', 'token_key', 'host', 'image',
    'privileged', 'tls_verify', 'socket_mount', 'volumes', 'security_opt',
    'environment', 'comment', 'helper_image', 'disable_entrypoint_overwrite',
    'oom_kill_disable', 'disable_cache', 'shm_size', 'network_mtu', 'cache',
    'allowed_images', 'allowed_pull_policies',
  ]
  $rootless_gitlab_runner::effective_runners.each |$r| {
    $unknown = $r.keys - $recognised_runner_keys
    unless $unknown.empty {
      fail("rootless_gitlab_runner: runner '${r['name']}' has unrecognised key(s) ${unknown.join(', ')} — check for a typo")
    }
  }

  # Merge secret tokens into the runner list at apply time. The tokens store is
  # Sensitive (typed Sensitive; module lookup_options convert_to wraps a
  # plain-YAML or eyaml store on lookup). Unwrap it once here to build the
  # render — the plaintext lives only in this compile-time local, never in the
  # catalog, because the rendered file content is re-wrapped Sensitive below.
  # With a secret store present, every runner must carry a token_key that
  # resolves — a missing or unresolvable key is a typo or a missed provisioning
  # step, so fail loud instead of registering a runner with a blank token. With
  # no store at all (CI, checkouts without secrets), blank tokens render by
  # design.
  $tokens = $rootless_gitlab_runner::runner_tokens.unwrap
  $rendered_runners = $rootless_gitlab_runner::effective_runners.map |$r| {
    $tk = $r['token_key']
    if !$tokens.empty {
      if !($tk =~ String) {
        fail(join([
          "rootless_gitlab_runner: runner '${r['name']}' has no token_key ",
          'but the secret store is populated — every runner needs a resolvable token_key',
        ]))
      }
      if !($tokens[$tk] =~ String) {
        fail("rootless_gitlab_runner: token_key '${tk}' of runner '${r['name']}' not found in the secret store's tokens hash")
      }
    }
    $token = ($tk =~ String and $tokens[$tk] =~ String) ? {
      true    => $tokens[$tk],
      default => '',
    }
    $r + { 'token' => $token }
  }

  # The secret-store directory is managed (root-owned, 0700); the secret file
  # inside it is host-provisioned and intentionally not managed.
  file { $rootless_gitlab_runner::secret_store_path:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  # Where this module owns the privilege-dropped manager service, own its config
  # directory too: the gitlab-runner package creates /etc/gitlab-runner as 0700
  # root:root, which User=gitlab-runner can neither traverse to reach its own
  # config.toml nor write to. The privilege-dropped manager both reads
  # config.toml and *writes* /etc/gitlab-runner/.runner_system_id on startup, so
  # the directory is root-owned but group-writable by the runner group (0770).
  # This adds no real exposure: the runner user already owns config.toml (0600),
  # so it can rewrite its own config regardless of the directory mode, and
  # `other` has no access. Managed here (not in service.pp) so it stays in the
  # same class as the config file that autorequires it as its parent.
  if $rootless_gitlab_runner::manage_runner_service {
    $config_dir = dirname($rootless_gitlab_runner::config_path)
    file { $config_dir:
      ensure => directory,
      owner  => 'root',
      group  => $rootless_gitlab_runner::config_group,
      mode   => '0770',
    }

    # gitlab-runner writes a persistent system-id file next to config.toml on
    # startup. The package's postinst starts the service as root at install —
    # before this module's privilege-drop drop-in is in effect — so the file is
    # created root-owned 0600, which the privilege-dropped manager then cannot
    # read (it fails loud: "reading from runner system ID file: permission
    # denied"). Own it as the service user so the dropped manager can read the
    # root-created file; the content is the runner's to generate, so manage
    # existence + ownership only, never the content. Applied before the service
    # restart (config precedes service in the class order), so the first apply
    # converges in one run.
    file { "${config_dir}/.runner_system_id":
      ensure => file,
      owner  => $rootless_gitlab_runner::service_user,
      group  => $rootless_gitlab_runner::config_group,
      mode   => '0600',
    }
  }

  # Always managed, no toggle: rendering the runner config is this module's
  # core purpose (same rubric as the no-detach-netns drop-in). The content is
  # Sensitive because it carries the runner tokens, keeping them out of the
  # compiled catalog, reports/PuppetDB, and --show_diff output.
  file { $rootless_gitlab_runner::config_path:
    ensure  => file,
    owner   => $rootless_gitlab_runner::config_owner,
    group   => $rootless_gitlab_runner::config_group,
    mode    => $rootless_gitlab_runner::config_mode,
    content => Sensitive(epp('rootless_gitlab_runner/config.toml.epp', {
      'concurrent'         => $rootless_gitlab_runner::concurrent,
      'check_interval'     => $rootless_gitlab_runner::check_interval,
      'connection_max_age' => $rootless_gitlab_runner::connection_max_age,
      'shutdown_timeout'   => $rootless_gitlab_runner::shutdown_timeout,
      'runners'            => $rendered_runners,
      'docker_socket_path' => $socket_path,
    })),
  }

  # The no-detach-netns drop-in lives deep in the runner user's systemd tree
  # (~/.config/systemd/user/docker.service.d/). The rootless-docker bring-up
  # creates ~/.config/systemd/user, but relying on that couples us to the
  # setuptool's side effects — and Puppet's file type never creates parents.
  # Own the whole parent chain explicitly (ordered after the bring-up by the
  # class order), so the first apply on a fresh host can always place the
  # drop-in, even if a future setuptool changes what it creates. Puppet
  # autorequires each managed parent, so the chain applies top-down.
  $dropin_dir       = dirname($rootless_gitlab_runner::dropin_path)
  $user_units_dir   = dirname($dropin_dir)
  $user_systemd_dir = dirname($user_units_dir)
  $user_config_dir  = dirname($user_systemd_dir)
  file { [$user_config_dir, $user_systemd_dir, $user_units_dir, $dropin_dir]:
    ensure => directory,
    owner  => $rootless_gitlab_runner::runner_user,
    group  => $rootless_gitlab_runner::runner_user,
    mode   => '0755',
  }

  # Always managed, no toggle: keeps rootless dockerd working across
  # rootless-extras upgrades by pinning
  # DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=false.
  file { $rootless_gitlab_runner::dropin_path:
    ensure  => file,
    owner   => $rootless_gitlab_runner::runner_user,
    group   => $rootless_gitlab_runner::runner_user,
    mode    => $rootless_gitlab_runner::dropin_mode,
    source  => 'puppet:///modules/rootless_gitlab_runner/no-detach-netns.conf',
    require => File[$dropin_dir],
  }

  # Where this module owns the rootless daemon, make the drop-in effective on
  # the same apply that first places it: reload the user unit files and restart
  # docker as the runner user. Without this the daemon keeps running with the
  # upstream DETACH_NETNS default until an unrelated reboot — the exact failure
  # mode the drop-in exists to prevent. refreshonly, so steady-state applies
  # (drop-in unchanged) neither reload nor restart. Where the daemon is owned
  # elsewhere (manage_rootless_docker off), restarts stay the operator's call.
  if $rootless_gitlab_runner::manage_rootless_docker {
    exec { 'rootless_gitlab_runner docker daemon-reload (no-detach-netns)':
      command     => 'systemctl --user daemon-reload && systemctl --user try-restart docker',
      user        => $rootless_gitlab_runner::runner_user,
      environment => $rootless_gitlab_runner::runner_user_env,
      path        => ['/usr/bin', '/bin'],
      provider    => 'shell',
      refreshonly => true,
      subscribe   => File[$rootless_gitlab_runner::dropin_path],
    }
  }
}
