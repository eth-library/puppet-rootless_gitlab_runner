# @summary Owns the runner group, user and home.
# @api private
class rootless_gitlab_runner::user {
  assert_private()

  $account = $rootless_gitlab_runner::runner_account

  if $account['manage'] {
    $runner_name = $account['name']

    group { $runner_name:
      ensure => present,
      system => true,
    }

    # Home internals (.ssh, .config, ...) are never managed; managehome only
    # creates the directory on first apply.
    user { $runner_name:
      ensure     => present,
      system     => true,
      uid        => $account['uid'],
      gid        => $runner_name,
      home       => $account['home'],
      managehome => true,
      shell      => '/bin/bash',
      require    => Group[$runner_name],
    }
  }
}
