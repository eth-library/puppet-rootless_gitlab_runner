# @summary Owns the runner group, user and home.
# @api private
class rootless_gitlab_runner::user {
  assert_private()

  if $rootless_gitlab_runner::manage_runner_user {
    $runner_user = $rootless_gitlab_runner::runner_user

    group { $runner_user:
      ensure => present,
      system => true,
    }

    # Home internals (.ssh, .config, ...) are never managed; managehome only
    # creates the directory on first apply.
    user { $runner_user:
      ensure     => present,
      system     => true,
      uid        => $rootless_gitlab_runner::runner_uid,
      gid        => $runner_user,
      home       => $rootless_gitlab_runner::runner_home,
      managehome => true,
      shell      => '/bin/bash',
      require    => Group[$runner_user],
    }
  }
}
