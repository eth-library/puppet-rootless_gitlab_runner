# @summary Installs the standalone apply script and the optional self-update loop.
# @api private
class rootless_gitlab_runner::self_update {
  assert_private()

  $standalone = $rootless_gitlab_runner::standalone
  $apply_script = '/usr/local/sbin/rootless-gitlab-runner-apply'
  $control_repository_path = $standalone['control_repository_path']

  # The apply script installs on any standalone host, not only with the
  # self-update loop: it is the single definition of the apply command for
  # manual runs and for the loop alike.
  if $standalone['manage'] {
    # The manifest, module directory and Hiera configuration derive strictly
    # from the documented control-repository layout — the layout is the
    # contract, not a parameter.
    file { $apply_script:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      content => epp('rootless_gitlab_runner/apply.sh.epp', {
        'puppetfile_path'  => "${control_repository_path}/Puppetfile",
        'manifest_path'    => "${control_repository_path}/puppet/manifests/site.pp",
        'module_directory' => "${control_repository_path}/puppet/modules",
        'hiera_config'     => "${control_repository_path}/puppet/hiera.yaml",
        'confdir'          => $standalone['puppet_confdir'],
        'vardir'           => $standalone['puppet_vardir'],
      }),
    }
  }

  if $standalone['self_update']['manage'] {
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

    file { $healthcheck_script:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      content => epp('rootless_gitlab_runner/healthcheck.sh.epp', {
        'runner_name'               => $rootless_gitlab_runner::runner_account['name'],
        'runtime_dir'               => $rootless_gitlab_runner::runtime_dir,
        'socket_path'               => $rootless_gitlab_runner::socket_path,
        'control_repository_path'   => $control_repository_path,
        'control_repository_branch' => $standalone['control_repository_branch'],
        'service_name'              => $rootless_gitlab_runner::service_name,
      }),
    }

    file { '/etc/systemd/system/gitlab-runner-apply.service':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/apply.service.epp', {
        'apply_script'              => $apply_script,
        'control_repository_path'   => $control_repository_path,
        'control_repository_branch' => $standalone['control_repository_branch'],
        'apply_timeout'             => $standalone['self_update']['apply_timeout'],
        'puppet_bindir'             => $standalone['puppet_bindir'],
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (self-update)'],
    }

    file { '/etc/systemd/system/gitlab-runner-apply.timer':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/apply.timer.epp', {
        'apply_interval' => $standalone['self_update']['apply_interval'],
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
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (self-update)'],
    }

    file { '/etc/systemd/system/gitlab-runner-healthcheck.timer':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/healthcheck.timer.epp', {
        'healthcheck_interval' => $standalone['healthcheck_interval'],
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
