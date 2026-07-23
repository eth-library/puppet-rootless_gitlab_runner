# @summary Installs the standalone apply script and liveness healthcheck, plus the optional self-update loop.
# @api private
class rootless_gitlab_runner::self_update {
  assert_private()

  $standalone = $rootless_gitlab_runner::standalone
  $apply_script = '/usr/local/sbin/rootless-gitlab-runner-apply'
  $healthcheck_script = '/usr/local/sbin/rootless-gitlab-runner-healthcheck'
  $control_repository_path = $standalone['control_repository_path']

  # The apply script and the liveness healthcheck install on any standalone
  # host, not only with the self-update loop: the apply script is the single
  # definition of the apply command for manual runs and the loop alike, and
  # liveness (manager service, rootless daemon) is meaningful whether or not
  # an automatic loop drives convergence. The loop-supervision checks layer
  # into the healthcheck script only when self_update.manage is on (rendered
  # in the template).
  if $standalone['manage'] {
    # This class's own reload point; refreshonly. Deliberately separate from
    # service.pp's exec: sharing one would order it both before the runner
    # service (its subscriber) and after these unit files (its notifiers) —
    # a dependency cycle under the service -> self_update class ordering. The
    # apply units below (gated on self_update.manage) notify it too, which is
    # sound because self_update.manage implies standalone.manage.
    exec { 'rootless_gitlab_runner daemon-reload (standalone)':
      command     => 'systemctl daemon-reload',
      path        => ['/usr/bin', '/bin'],
      refreshonly => true,
    }

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

    file { $healthcheck_script:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0755',
      content => epp('rootless_gitlab_runner/healthcheck.sh.epp', {
        'runner_name'               => $rootless_gitlab_runner::runner_name,
        'runtime_dir'               => $rootless_gitlab_runner::runtime_dir,
        'socket_path'               => $rootless_gitlab_runner::socket_path,
        'control_repository_path'   => $control_repository_path,
        'control_repository_branch' => $standalone['control_repository_branch'],
        'service_name'              => $rootless_gitlab_runner::service_name,
        'self_update_manage'        => $standalone['self_update']['manage'],
      }),
    }

    file { '/etc/systemd/system/gitlab-runner-healthcheck.service':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/healthcheck.service.epp', {
        'healthcheck_script' => $healthcheck_script,
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (standalone)'],
    }

    file { '/etc/systemd/system/gitlab-runner-healthcheck.timer':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/healthcheck.timer.epp', {
        'healthcheck_interval' => $standalone['healthcheck_interval'],
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (standalone)'],
    }

    # The timer subscribes to its unit files (via the daemon-reload exec), so a
    # changed interval takes effect in the same apply, not the next boot.
    service { 'gitlab-runner-healthcheck.timer':
      ensure    => running,
      enable    => true,
      subscribe => [
        File['/etc/systemd/system/gitlab-runner-healthcheck.service'],
        File['/etc/systemd/system/gitlab-runner-healthcheck.timer'],
        Exec['rootless_gitlab_runner daemon-reload (standalone)'],
      ],
    }
  }

  if $standalone['self_update']['manage'] {
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
      notify  => Exec['rootless_gitlab_runner daemon-reload (standalone)'],
    }

    file { '/etc/systemd/system/gitlab-runner-apply.timer':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('rootless_gitlab_runner/apply.timer.epp', {
        'apply_interval' => $standalone['self_update']['apply_interval'],
      }),
      notify  => Exec['rootless_gitlab_runner daemon-reload (standalone)'],
    }

    # The timer subscribes to its unit files (via the daemon-reload exec), so a
    # changed interval takes effect in the same apply, not the next boot.
    service { 'gitlab-runner-apply.timer':
      ensure    => running,
      enable    => true,
      subscribe => [
        File['/etc/systemd/system/gitlab-runner-apply.service'],
        File['/etc/systemd/system/gitlab-runner-apply.timer'],
        Exec['rootless_gitlab_runner daemon-reload (standalone)'],
      ],
    }
  }
}
