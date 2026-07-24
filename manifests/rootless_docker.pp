# @summary Brings up the rootless docker user daemon behind a fail-loud preflight.
# @api private
class rootless_gitlab_runner::rootless_docker {
  assert_private()

  if $rootless_gitlab_runner::rootless_docker['manage'] {
    $runner_user = $rootless_gitlab_runner::runner_name
    $runner_home = $rootless_gitlab_runner::runner_home
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
    # --system` allocates none, so the ranges are provisioned here with the rest
    # of the rootless runtime: also when the runner account itself is owned
    # externally (runner_account.manage off). usermod (shadow 4.8.1) writes the
    # entry under the shadow file lock and fails loud when the user is absent.
    #
    # subid_count is a declared minimum width, enforced grow-only per file
    # (/etc/subuid, /etc/subgid). The structured subid fact reports each file's
    # current entries, so the class reasons about real host state that rspec and
    # --noop cannot see, and drives every outcome from that one source:
    #   create — no entry yet: write start:count (the greenfield path). Always
    #            declared and grep-guarded, so it is correct even without the fact.
    #   widen  — a contiguous block anchored at the declared start but narrower
    #            than declared: add only the missing tail as a further contiguous
    #            range. The add is pure (no --del), so it succeeds even while the
    #            runner user has a live session; --del would trip usermod's
    #            running-process guard on the lingering systemd --user manager and
    #            fail on exactly the converged hosts that need a widen. The tail
    #            offset comes from the fact, so the command is literal, and the
    #            guard re-asserts the covered width still matches, so a host
    #            changed since fact collection is skipped, not double-added. The
    #            existing lower ranges are left untouched (a prefix superset) and
    #            rootlesskit maps every range, so the effective width is their sum
    #            and container/image ownership is untouched.
    #   advise — everything else is neither created nor widened: a wider-than-
    #            declared entry, or a foreign-start, gapped, or overlapping range
    #            wide enough in sum, warns (declared data must mirror the host); a
    #            too-narrow foreign range fails loud at the preflight below.
    # warning() is a log line, not a resource, so the apply stays change-free and
    # --noop clean (an exec/notify warning would report a change every apply);
    # only the exact-match state is silent. Guards test host state and exit 0/1 —
    # no PATH probe.
    $subid_first  = $rootless_gitlab_runner::rootless_docker['subid_start']
    $subid_count  = $rootless_gitlab_runner::rootless_docker['subid_count']
    $subid_last   = $subid_first + $subid_count - 1
    $subid_report = $facts['rootless_gitlab_runner_subids']
    $subid_files  = {
      'subuid' => { 'add' => '--add-subuids' },
      'subgid' => { 'add' => '--add-subgids' },
    }
    $subid_files.each |$f, $flag| {
      # This file's entries, from the fact: all owners, and the runner user's own
      # ranges (empty when the fact has not run, e.g. the factless specs).
      $owners = $subid_report =~ Hash ? { true => pick_default($subid_report[$f], {}), default => {} }
      $ranges = pick_default($owners[$runner_user], [])

      # create: no entry yet for the runner user.
      exec { "rootless_gitlab_runner ${f} entry":
        command  => "usermod ${flag['add']} ${subid_first}-${subid_last} ${runner_user}",
        unless   => "grep -q '^${runner_user}:' /etc/${f}",
        path     => ['/usr/sbin', '/usr/bin', '/bin'],
        provider => 'shell',
        before   => Exec['rootless_gitlab_runner preflight'],
      }

      # widen / advise on the runner user's own entries. The create path and an
      # additive widen both leave the runner's ranges as one contiguous block
      # anchored at the declared start; detect that shape and its covered width by
      # folding the ranges (ascending) from subid_first, breaking on the first
      # gap, overlap, or foreign start.
      $sorted = $ranges.sort |$a, $b| { $a['start'] - $b['start'] }
      $fold   = $sorted.reduce([$subid_first, true]) |$acc, $r| {
        ($acc[1] and $r['start'] == $acc[0]) ? {
          true    => [$acc[0] + $r['count'], true],
          default => [$acc[0], false],
        }
      }
      $anchored = $ranges.length > 0 and $fold[1]
      $have     = $fold[0] - $subid_first  # covered width, valid when anchored

      if $anchored {
        if $have < $subid_count {
          # Grow-only, additive: add only the missing tail as a contiguous range.
          # A pure --add succeeds even while the runner user has a live session;
          # a --del would trip usermod's running-process guard on the lingering
          # systemd --user manager, so delete-and-re-add fails on exactly the
          # converged hosts that need a widen. The existing lower ranges are an
          # untouched prefix, and rootlesskit maps every range, so the effective
          # width is their sum. onlyif re-asserts the covered width the fact saw,
          # so a host changed since fact collection is skipped (not double-added),
          # and the widen no-ops once the sum reaches the count.
          $tail_first = $subid_first + $have
          exec { "rootless_gitlab_runner ${f} widen":
            command  => "usermod ${flag['add']} ${tail_first}-${subid_last} ${runner_user}",
            onlyif   => "awk -F: -v u='${runner_user}' '\$1==u{s+=\$3} END{exit !(s==${have})}' /etc/${f}",
            path     => ['/usr/sbin', '/usr/bin', '/bin'],
            provider => 'shell',
            before   => Exec['rootless_gitlab_runner preflight'],
            notify   => Exec['rootless_gitlab_runner rootless docker restart (subid widen)'],
          }
        } elsif $have > $subid_count {
          warning(join([
            "rootless_gitlab_runner: /etc/${f} grants ${runner_user} ${subid_first}:${have}, wider than the",
            "declared subid_count ${subid_count}; the module never shrinks a range. Raise subid_count to",
            'match the host, or narrow the entry by hand.',
          ], ' '))
        }
      } elsif $ranges.length > 0 {
        # Not an anchored contiguous block: a foreign start, a gap, or an internal
        # overlap. Never rewritten. Wide enough in sum warns; too narrow is caught
        # loud by the preflight, not here.
        $summed = $ranges.reduce(0) |$m, $r| { $m + $r['count'] }
        if $summed >= $subid_count {
          warning(join([
            "rootless_gitlab_runner: /etc/${f} for ${runner_user} does not mirror the declared range",
            "${subid_first}:${subid_count} and is left untouched. Align subid_start/subid_count with the",
            'host allocation to silence this.',
          ], ' '))
        }
      }

      # Any other user's range overlapping the declared one: usermod adds no
      # overlap check, so an overlap means two users share container UIDs.
      $owners.each |$owner, $oranges| {
        unless $owner == $runner_user {
          $oranges.each |$r| {
            $o_last = $r['start'] + $r['count'] - 1
            if $r['start'] <= $subid_last and $o_last >= $subid_first {
              warning(join([
                "rootless_gitlab_runner: the declared range ${subid_first}-${subid_last} overlaps",
                "${owner}'s ${r['start']}-${o_last} in /etc/${f}; the two users would share container",
                'UIDs. Choose a non-overlapping subid_start.',
              ], ' '))
            }
          }
        }
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
    #
    # The subuid/subgid clauses sum the runner user's entries and compare the
    # total against the declared subid_count (rootlesskit maps every range, so
    # the sum is the effective width). A module-shaped host is widened above
    # before this runs; a foreign range wide enough in sum passes; a foreign
    # range too narrow fails here with the declared count and the remedies.
    $preflight_ok = join([
      'test -x /usr/bin/newuidmap',
      "awk -F: -v u='${runner_user}' -v need=${subid_count} '\$1==u{sum+=\$3} END{exit !(sum>=need)}' /etc/subuid",
      "awk -F: -v u='${runner_user}' -v need=${subid_count} '\$1==u{sum+=\$3} END{exit !(sum>=need)}' /etc/subgid",
      "test -e /var/lib/systemd/linger/${runner_user}",
      'test -f /sys/fs/cgroup/cgroup.controllers',
    ], ' && ')

    exec { 'rootless_gitlab_runner preflight':
      command  => join([
        'echo "rootless_gitlab_runner preflight failed:',
        'need newuidmap,',
        "subuid+subgid totalling >= ${subid_count} for ${runner_user}",
        '(widen the foreign range, or align subid_start/subid_count with it),',
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

    # A widened range only takes effect when rootlesskit re-creates the user
    # namespace, i.e. a rootless-daemon restart — which drops running job
    # containers (rootless mode has no live-restore; the containers are children
    # of the rootlesskit namespace). The netns drop-in already accepts this same
    # trade; CI-side job retry is the documented mitigation, and no drain is
    # orchestrated (a bounded wait-until-empty would risk the apply timing out).
    # Notified only by an actual widen above, so it fires only when the width
    # changed; a subid widen alters no unit file, so try-restart alone (no
    # daemon-reload). try-restart no-ops on greenfield where no daemon runs yet.
    exec { 'rootless_gitlab_runner rootless docker restart (subid widen)':
      command     => 'systemctl --user try-restart docker',
      user        => $runner_user,
      environment => $user_env,
      path        => ['/usr/bin', '/bin'],
      refreshonly => true,
      require     => Exec['rootless_gitlab_runner setuptool install'],
    }
  }
}
