# @summary Manages the runner system service and its privilege-drop drop-in.
# @api private
class rootless_gitlab_runner::service {
  assert_private()

  # One owner for the manager service and its privilege-drop drop-in; the
  # privilege posture is data (service_user, service_environment).
  if $rootless_gitlab_runner::manage_runner_service {
    $service_name       = $rootless_gitlab_runner::service_name
    $service_dropin_dir = "/etc/systemd/system/${service_name}.service.d"

    file { $service_dropin_dir:
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }

    # Reload point for this class's unit-file changes; refreshonly. Deliberately
    # NOT shared with self_update: one exec serving both classes puts it before
    # Service[gitlab-runner] and after the self-update unit files at once —
    # a dependency cycle under the service -> self_update class ordering.
    exec { 'rootless_gitlab_runner daemon-reload':
      command     => 'systemctl daemon-reload',
      path        => ['/usr/bin', '/bin'],
      refreshonly => true,
    }

    file { "${service_dropin_dir}/10-rootless.conf":
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/service-dropin.conf.epp', {
        'service_user'             => $rootless_gitlab_runner::service_user,
        'service_environment'      => $rootless_gitlab_runner::real_service_environment,
        'runner_binary'            => $rootless_gitlab_runner::runner_binary,
        'runner_home'              => $rootless_gitlab_runner::runner_home,
        'config_path'              => $rootless_gitlab_runner::config_path,
        'service_name'             => $service_name,
        'service_kill_signal'      => $rootless_gitlab_runner::service_kill_signal,
        'service_timeout_stop_sec' => $rootless_gitlab_runner::service_timeout_stop_sec,
      }),
      require => File[$service_dropin_dir],
      notify  => Exec['rootless_gitlab_runner daemon-reload'],
    }

    # Not subscribed to the rendered config: GitLab Runner re-reads config.toml
    # within ~3s on its own, so a config change needs no restart — and a
    # restart sends SIGTERM, aborting every running job. Only unit-file changes
    # (via the daemon-reload) warrant restarting the manager.
    service { $service_name:
      ensure    => running,
      enable    => true,
      subscribe => [
        Exec['rootless_gitlab_runner daemon-reload'],
      ],
    }
  }
}
