# @summary Installs the standalone self-update units and the healthcheck.
# @api private
class rootless_gitlab_runner::self_update {
  assert_private()

  if $rootless_gitlab_runner::manage_standalone_self_update {
    $apply_script       = '/usr/local/sbin/rootless-gitlab-runner-apply'
    $healthcheck_script = '/usr/local/sbin/rootless-gitlab-runner-healthcheck'

    # This class's own reload point; refreshonly. Deliberately separate from
    # service.pp's exec: sharing one would order it both before the runner
    # service (its subscriber) and after these unit files (its notifiers) —
    # a dependency cycle under the service -> self_update class ordering.
    exec { 'rootless_gitlab_runner daemon-reload (self-update)':
      command     => 'systemctl daemon-reload',
      path        => ['/usr/bin', '/bin'],
      refreshonly => true,
    }

    file { $apply_script:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      content => epp('rootless_gitlab_runner/apply.sh.epp', {
        'repo_path'     => $rootless_gitlab_runner::repo_path,
        'manifest_path' => $rootless_gitlab_runner::real_manifest_path,
        'module_dir'    => $rootless_gitlab_runner::real_module_dir,
        'hiera_config'  => $rootless_gitlab_runner::real_hiera_config,
        'confdir'       => $rootless_gitlab_runner::apply_confdir,
        'vardir'        => $rootless_gitlab_runner::apply_vardir,
      }),
    }

    file { $healthcheck_script:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      content => epp('rootless_gitlab_runner/healthcheck.sh.epp', {
        'service_name' => $rootless_gitlab_runner::service_name,
        'runner_user'  => $rootless_gitlab_runner::runner_user,
        'runtime_dir'  => $rootless_gitlab_runner::runtime_dir,
        'socket_path'  => $rootless_gitlab_runner::socket_path,
        'repo_path'    => $rootless_gitlab_runner::repo_path,
        'repo_branch'  => $rootless_gitlab_runner::repo_branch,
      }),
    }

    file { '/etc/systemd/system/gitlab-runner-apply.service':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/apply.service.epp', {
        'apply_script'    => $apply_script,
        'repo_path'       => $rootless_gitlab_runner::repo_path,
        'repo_branch'     => $rootless_gitlab_runner::repo_branch,
        'apply_timeout'   => $rootless_gitlab_runner::apply_timeout,
        'puppet_bindir'   => $rootless_gitlab_runner::puppet_bindir,
        'on_failure_unit' => $rootless_gitlab_runner::on_failure_unit,
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (self-update)'],
    }

    file { '/etc/systemd/system/gitlab-runner-apply.timer':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/apply.timer.epp', {
        'apply_interval' => $rootless_gitlab_runner::apply_interval,
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (self-update)'],
    }

    file { '/etc/systemd/system/gitlab-runner-healthcheck.service':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/healthcheck.service.epp', {
        'healthcheck_script' => $healthcheck_script,
        'on_failure_unit'    => $rootless_gitlab_runner::on_failure_unit,
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (self-update)'],
    }

    file { '/etc/systemd/system/gitlab-runner-healthcheck.timer':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/healthcheck.timer.epp', {
        'healthcheck_interval' => $rootless_gitlab_runner::healthcheck_interval,
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (self-update)'],
    }

    # The timers subscribe to their unit files (via the daemon-reload exec),
    # so a changed interval takes effect in the same apply, not the next boot.
    service { 'gitlab-runner-apply.timer':
      ensure    => running,
      enable    => true,
      subscribe => [
        File['/etc/systemd/system/gitlab-runner-apply.service'],
        File['/etc/systemd/system/gitlab-runner-apply.timer'],
        Exec['rootless_gitlab_runner daemon-reload (self-update)'],
      ],
    }

    service { 'gitlab-runner-healthcheck.timer':
      ensure    => running,
      enable    => true,
      subscribe => [
        File['/etc/systemd/system/gitlab-runner-healthcheck.service'],
        File['/etc/systemd/system/gitlab-runner-healthcheck.timer'],
        Exec['rootless_gitlab_runner daemon-reload (self-update)'],
      ],
    }
  }
}
