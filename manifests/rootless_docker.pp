# @summary Brings up the rootless docker user daemon behind a fail-loud preflight.
# @api private
class rootless_gitlab_runner::rootless_docker {
  assert_private()

  if $rootless_gitlab_runner::rootless_docker['manage'] {
    $runner_user = $rootless_gitlab_runner::runner_account['name']
    $runner_home = $rootless_gitlab_runner::runner_account['home']
    $runner_uid  = $rootless_gitlab_runner::runner_account['uid']
    $runtime_dir = $rootless_gitlab_runner::runtime_dir
    $user_env    = $rootless_gitlab_runner::runner_user_env
    # The setuptool ships at the path the docker-ce-rootless-extras package
    # defines; if it is absent the install exec below fails loud (a missing
    # command is a command failure, not a guard failure).
    $setuptool   = '/usr/bin/dockerd-rootless-setuptool.sh'
    # The user unit the setuptool generates, under the shared systemd user dir.
    $docker_user_unit = "${rootless_gitlab_runner::user_systemd_dir}/docker.service"

    # A fresh docker-ce install leaves the rootful system daemon running: the
    # package postinst starts docker.service + docker.socket as root, and
    # anything that reaches that root-owned socket controls the host. The
    # containerd.io package likewise enables and starts containerd.service as
    # root — an idle root daemon nothing uses here (the rootless dockerd runs
    # its own containerd as the runner user). The rootless daemon needs none of
    # them. Stop and mask all three so only the rootless daemon runs: mask (a
    # /dev/null unit symlink) blocks manual starts, socket activation and
    # dependency pulls, and survives package upgrades (deb-systemd-invoke skips
    # masked units), while `stopped` covers an already-running daemon. Class
    # ordering places this after packages, so a same-run install is masked in
    # the same apply.
    service { ['docker.service', 'docker.socket', 'containerd.service']:
      ensure   => stopped,
      enable   => mask,
      # Explicit: mask needs the systemd provider's `maskable` feature, and
      # provider auto-selection must not fall back to a non-systemd provider.
      provider => 'systemd',
    }

    # Lingering gives the runner user a systemd user manager and
    # XDG_RUNTIME_DIR=/run/user/<uid> at boot, without a login. logind records
    # it as a flag file under /var/lib/systemd/linger/.
    exec { 'rootless_gitlab_runner enable-linger':
      command => "loginctl enable-linger ${runner_user}",
      unless  => "test -e /var/lib/systemd/linger/${runner_user}",
      path    => ['/usr/bin', '/bin'],
    }

    # Rootless docker needs >= 65536 subordinate IDs per user, and `useradd
    # --system` allocates none, so the ranges are provisioned here with the
    # rest of the rootless runtime: also when the runner account itself is
    # owned externally (runner_account.manage off). usermod (--add-subuids /
    # --add-subgids, shadow 4.8.1) takes an inclusive range and writes the
    # entry under the shadow file lock; it fails loud when the user does not
    # exist yet. Guarded per file: an existing entry for the user is left
    # alone (no drift war over externally chosen ranges).
    $subid_first = $rootless_gitlab_runner::rootless_docker['subid_start']
    $subid_last  = $subid_first + $rootless_gitlab_runner::rootless_docker['subid_count'] - 1
    $subid_flags = { 'subuid' => '--add-subuids', 'subgid' => '--add-subgids' }
    $subid_flags.each |$f, $flag| {
      exec { "rootless_gitlab_runner ${f} entry":
        command  => "usermod ${flag} ${subid_first}-${subid_last} ${runner_user}",
        unless   => "grep -q '^${runner_user}:' /etc/${f}",
        path     => ['/usr/sbin', '/usr/bin', '/bin'],
        provider => 'shell',
        before   => Exec['rootless_gitlab_runner preflight'],
      }
    }

    # Fail-loud preflight, silent when healthy: the success condition lives in
    # `unless` (prereqs OK => exec skipped, no change, clean --noop); a missing
    # prereq runs `command`, which prints the contract and exits 1 before any
    # half-install can happen.
    #
    # Guard contract: every clause must exit 0 or 1 — never 127. Puppet reserves
    # exit 127 from an exec guard for "the guard itself could not run" and turns
    # it into a raised error, and dash (Ubuntu's /bin/sh) exits 127 from a PATH
    # probe (`command -v`) on a missing binary. So test the packaged file, not
    # the PATH: /usr/bin/newuidmap is what jammy's uidmap package installs.
    $preflight_ok = join([
      'test -x /usr/bin/newuidmap',
      "awk -F: -v u='${runner_user}' '\$1 == u && \$3 >= 65536' /etc/subuid | grep -q .",
      "awk -F: -v u='${runner_user}' '\$1 == u && \$3 >= 65536' /etc/subgid | grep -q .",
      "test -e /var/lib/systemd/linger/${runner_user}",
      'test -f /sys/fs/cgroup/cgroup.controllers',
    ], ' && ')

    exec { 'rootless_gitlab_runner preflight':
      command  => join([
        'echo "rootless_gitlab_runner preflight failed:',
        'need newuidmap,',
        "subuid/subgid >= 65536 for ${runner_user},",
        'lingering enabled, and cgroup v2" >&2; exit 1',
      ], ' '),
      unless   => $preflight_ok,
      path     => ['/usr/bin', '/bin'],
      provider => 'shell',
      require  => Exec['rootless_gitlab_runner enable-linger'],
    }

    # cgroup-v2 delegation (user@.service.d/delegate.conf) is deliberately not
    # managed: it would be the module's only system-wide write, affecting every
    # user slice on the host. Without it CPU/cpuset/IO job limits are silently
    # unenforced — a recorded known limitation.

    # loginctl enable-linger returns before the runner user's systemd manager
    # and session bus are up, so a setuptool run microseconds later cannot reach
    # `systemctl --user`: it would skip the systemd-unit half yet still exit 0.
    # Start the user manager and block until its bus socket is live, so the
    # bring-up below runs against a ready session. Idempotent: at steady state
    # the bus already exists and `unless` skips the whole exec.
    exec { 'rootless_gitlab_runner await user session':
      command  => "systemctl start user@${runner_uid}.service && timeout 30 sh -c 'until test -S ${runtime_dir}/bus; do sleep 0.5; done'",
      unless   => "test -S ${runtime_dir}/bus",
      path     => ['/usr/bin', '/bin'],
      provider => 'shell',
      require  => Exec['rootless_gitlab_runner preflight'],
    }

    # The setuptool ships with docker-ce-rootless-extras; it is invoked, not
    # reimplemented. Gate on installed state — the rootless docker user unit
    # existing — not on `${setuptool} check`, which verifies prerequisites
    # only. The module's own preflight already guarantees those prerequisites
    # pass, so a `check` guard would judge the install already done and skip it
    # on a fresh host, bringing the daemon up never. Daemon health is owned by
    # the healthcheck, not by this guard. Runs as the runner user under the
    # explicit runner-user environment contract, after the session is ready.
    #
    # Fail loud: the setuptool can exit 0 having skipped the systemd-unit half,
    # so the `creates` guard alone cannot tell a real install from a no-op
    # success. Assert the user unit exists after install, turning a silent skip
    # into a hard failure.
    exec { 'rootless_gitlab_runner setuptool install':
      command     => "${setuptool} install && test -f ${docker_user_unit}",
      creates     => $docker_user_unit,
      user        => $runner_user,
      environment => $user_env,
      path        => ['/usr/bin', '/bin'],
      cwd         => $runner_home,
      provider    => 'shell',
      require     => Exec['rootless_gitlab_runner await user session'],
    }
  }
}
