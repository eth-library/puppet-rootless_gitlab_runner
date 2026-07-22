# @summary Owns the runner group, user and home.
# @api private
class rootless_gitlab_runner::user {
  assert_private()

  $account = $rootless_gitlab_runner::runner_account

  if $account['manage'] {
    # Identity locals hoisted in init.pp; only manage and uid stay on $account.
    $runner_name  = $rootless_gitlab_runner::runner_name
    $runner_group = $rootless_gitlab_runner::runner_group

    group { $runner_group:
      ensure => present,
      system => true,
    }

    # Home internals (.ssh, .config, ...) are never managed; managehome only
    # creates the directory on first apply.
    user { $runner_name:
      ensure     => present,
      system     => true,
      uid        => $account['uid'],
      gid        => $runner_group,
      home       => $rootless_gitlab_runner::runner_home,
      managehome => true,
      shell      => '/bin/bash',
      require    => Group[$runner_group],
    }
  }
}
