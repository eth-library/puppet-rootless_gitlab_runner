# Standalone deployment

This page is the runbook for standalone deployments. A standalone host converges itself:
`puppet apply` [\[1\]](#ref-1) runs directly on the host from a control-repository checkout
deployed with r10k [\[2\]](#ref-2), and, optionally, a signed self-update loop keeps it
converging on the repository's protected branch on a systemd timer [\[3\]](#ref-3), with
every change still review-gated through git. It is not enrolled in central configuration
management: no Puppet server compiles and delivers its catalog as part of a fleet.

> [!NOTE]
> Everything shared with the fleet path, from the configuration contract to secrets and the
> security model, lives in the [README](../README.md) and applies to standalone hosts
> unchanged.

## Table of contents

- [When to use standalone](#when-to-use-standalone)
- [Installation](#installation)
- [Applying the configuration](#applying-the-configuration)
- [Automating with systemd](#automating-with-systemd)
- [Self-update loop](#self-update-loop)
  - [Prerequisites](#prerequisites)
  - [Supervision](#supervision)
  - [Rolling back a commit](#rolling-back-a-commit)
- [References](#references)

## When to use standalone

Choose the standalone path for hosts with no Puppet server or r10k fleet behind them: a
machine that cannot join central configuration management, or a site with no Puppet
infrastructure at all. The optional self-update loop gives the host the continuous
convergence a Puppet agent would otherwise provide: it tracks its own signed
control-repository branch and re-applies on a timer. Standalone does not mean a single
machine: one control repository can drive one such host or several, each holding its own
checkout and applying itself.

A host already managed by a Puppet server (or any control-repository/r10k setup) should use
the fleet path instead: declare the class from a role or profile
(`include rootless_gitlab_runner`) and let the existing machinery deliver the same Hiera data
and secret store; see the [README](../README.md). Never run the self-update loop on a fleet
host: it would be a second deploy agent competing with the server's.

## Installation

This module is consumed from a small **control repository** per site: a `Puppetfile` pinning this
module by `:commit`, a `hiera.yaml`, a `site.pp` with `include rootless_gitlab_runner`, and the
Hiera node data. A ready-to-adapt skeleton of that layout ships with the module in
[`examples/`](../examples/) — the `Puppetfile`, `hiera.yaml`, `site.pp`, and `data/` assemble into
the control repository (see [`examples/README.md`](../examples/README.md) for the layout). Copy them,
replace the Puppetfile's `:commit` placeholder and the example host data, and you have a control
repository. Bootstrapping a host (run as root):

1. Install OpenVox 8 (the community Puppet distribution [\[4\]](#ref-4)), git and r10k (a
   Puppet-brand `puppet-agent` 8 works identically if preferred).

   Download the OpenVox apt-repository package for Ubuntu 22.04:

   ```
   wget https://apt.voxpupuli.org/openvox8-release-ubuntu22.04.deb
   ```

   Install it to enable the repository:

   ```
   sudo apt install ./openvox8-release-ubuntu22.04.deb
   ```

   Install the agent, git and r10k (r10k ships in Ubuntu's own `universe` component):

   ```
   sudo apt update && sudo apt install openvox-agent git r10k
   ```
2. Get the control repository onto the host.

   Clone it to a root-owned path:

   ```
   sudo git clone <control-repository-url> /opt/<control-repository>
   ```

   Change into the checkout:

   ```
   cd /opt/<control-repository>
   ```

   Fetch the modules pinned in its Puppetfile (this module and its dependencies):

   ```
   sudo r10k puppetfile install --puppetfile Puppetfile --moduledir puppet/modules
   ```
3. Create each runner in GitLab (UI or API) and copy its `glrt-` authentication token (see
   [Adding a runner](../README.md#adding-a-runner)).
4. Create the off-repository secret store `/etc/gitlab-runner-infra/secrets.yaml` (`0600`) with the
   runner tokens (see [Secrets](../README.md#secrets)).
5. Add a Hiera node file `puppet/data/nodes/<hostname>.yaml`, where `<hostname>` is the host's
   short hostname (the `networking.hostname` fact), describing the runners (start from
   [`examples/data/nodes/host.example.yaml`](../examples/data/nodes/host.example.yaml)).
6. Decide what the module manages on this host. Leave a `manage` toggle off to treat that
   concern as an external prerequisite the host already provides; turn it on to have the module
   set it up and keep it converged on every apply. See the toggle table under
   [Configuration contract](../README.md#configuration-contract).
7. Dry-run first to preview the changes without touching the host (from the control-repository
   checkout). The absolute path is required: OpenVox installs outside `sudo`'s default
   `secure_path`, so a bare `puppet` is not found:

   ```
   sudo /opt/puppetlabs/bin/puppet apply --noop --confdir /etc/gitlab-runner-infra/puppet --vardir /var/lib/grunner-puppet --modulepath puppet/modules --hiera_config puppet/hiera.yaml puppet/manifests/site.pp
   ```

8. If the preview looks right, apply for real (same command without `--noop`). With
   `standalone.manage: true` (as in the example node data), this apply also installs the apply
   script that carries every later manual run.
9. Optionally set `standalone.self_update.manage: true` to have the module install the timers
   that automate future applies (see [Automating with systemd](#automating-with-systemd)).
10. Check the result (see [Verifying the host](../README.md#verifying-the-host)).

Each `manage` toggle decides whether the module owns a concern and keeps it converged (on) or
treats it as an external prerequisite the host must provide (off). The semantics and the full
toggle table are in the [Configuration contract](../README.md#configuration-contract).

Because Puppet is idempotent, the same flow works on a **fresh host or an existing one**: each run
converges to the declared state and corrects drift, so it is safe to repeat.

## Applying the configuration

With `standalone.manage` on, the module installs
`/usr/local/sbin/rootless-gitlab-runner-apply` — the **single definition of the apply command**.
It runs `puppet apply` with an isolated `--confdir`/`--vardir` so it never collides with a
central Puppet agent, installs Puppetfile-pinned modules via r10k first (a no-op without a
Puppetfile), and forwards extra arguments to Puppet. The systemd apply service and manual runs
both use it, so the invocation is defined in exactly one place.

First, preview the changes without touching the host:

```
sudo /usr/local/sbin/rootless-gitlab-runner-apply --noop
```

`--noop` is forwarded to `puppet apply`, so it previews the host changes without making them.
It does not suppress the module-install step: when a `Puppetfile` is present the script runs
`r10k puppetfile install` first, which still updates the pinned modules on disk before the
preview.

Once the preview looks right, apply (idempotent):

```
sudo /usr/local/sbin/rootless-gitlab-runner-apply
```

The script uses `--detailed-exitcodes` [\[1\]](#ref-1): exit code 0 means no changes, 2 means changes were
applied (success, not failure), 4 or 6 mean failures.

With the self-update units installed (`standalone.self_update.manage`), prefer triggering a run through the apply service
rather than the script directly. It goes through the same fetch + signature-verify chain the
timer uses and serialises against it — the oneshot never overlaps a scheduled run:

```
sudo systemctl start gitlab-runner-apply.service
```

Running the script directly bypasses that serialisation and the fetch/verify step; keep it for
`--noop` previews and ad-hoc local runs.

Before the script exists (the first apply on a fresh host, or with `standalone.manage` off),
use the plain `puppet apply` invocation from step 7 of [Installation](#installation).

Configuration reload and graceful-shutdown behavior (a configuration change never restarts the
runner; a unit-file change restarts it gracefully) is the same on a standalone host as on any
other; see [Restarts and graceful shutdown](../README.md#restarts-and-graceful-shutdown) in the
README.

## Automating with systemd

With `standalone.manage` on, the module installs `gitlab-runner-healthcheck.service` + `.timer`
(liveness). With `standalone.self_update.manage` also on, it installs and keeps converged the
self-update loop, `gitlab-runner-apply.service` + `.timer` (fetch,
verify the commit signature, reset to the remote branch, apply through the apply script above,
default every 5 minutes), and layers the loop-supervision checks into the healthcheck. Nothing
needs to be copied or enabled by hand; the timers are started and enabled by the apply that
installs them.

Confirm the timers are scheduled (the healthcheck timer on any standalone host; the apply timer
with the self-update loop):

```
systemctl list-timers 'gitlab-runner-*'
```

systemd serialises runs (a oneshot service never overlaps itself, so no external locking is
needed), and `SuccessExitStatus=2` treats Puppet's "changes applied" exit code as success, so only
genuine failures are flagged. A failure leaves the unit in the failed state, visible in the
journal, in `systemctl list-units --failed`, and to any host monitoring that watches failed
units. For a push alert, attach `OnFailure=` to the apply or healthcheck service through a
host-side drop-in (for example
`/etc/systemd/system/gitlab-runner-apply.service.d/alert.conf` naming an alerting unit such as
`notify-failure@%n.service`); alerting units are deliberately consumer-side, not a module
parameter.
Auto-deploying `main` this way is safe because `main` is protected (merge request review plus a
required green pipeline) and only signed commits pass the `git verify-commit` gate, which
depends on the trust chain in the self-update [Prerequisites](#prerequisites) below.

## Self-update loop

With `standalone.self_update.manage` on, the module installs the self-update loop: a oneshot
systemd service and timer (default every 5 minutes) that fetch the control repository, run
`git verify-commit` on the remote branch tip, reset to it, install Puppetfile-pinned modules
with r10k, and re-apply through the apply script. The loop is only valid on a standalone host:
enabling it with `standalone.manage` off fails at compile time. The contract keys (intervals,
timeout) live under [`standalone.self_update`](../README.md#standaloneself_update) in the
README. Never enable the loop where a Puppet server or r10k already deploys the host: the
host would end up with two deploy agents fighting over its state.

### Prerequisites

These prerequisites (the pull credential and the commit-signing trust chain) matter only with
`standalone.self_update.manage` on; a host without the self-update loop needs none of them.

The self-update loop fetches and verifies the control repository before it applies, so three
things must be provisioned on the host first. The module does not create them; if any is
missing the loop fails loud on its first tick, by design: a broken trust chain must never
silently apply.

Signature verification is non-optional within the loop, by design: it is what makes unattended
auto-apply safer. To run without it, leave `standalone.self_update.manage` off and apply another
way (the apply script by hand, or an operator's own timer).

1. **A pull credential:** The apply service fetches `origin` as root. Provision a **read-only,
   project-scoped SSH deploy key** [\[5\]](#ref-5) in root's `~/.ssh` (with the matching `known_hosts`) so the
   fetch authenticates non-interactively. A missing or dead credential is caught by the
   healthcheck's staleness check: an unreachable origin fails loud rather than hiding behind a
   green apply timer.
2. **A pinned signature trust root:** The loop runs `git verify-commit` [\[6\]](#ref-6) on the branch tip and
   applies only if it passes. `verify-commit` checks the signature against root's configured
   trust root, and an **empty keyring makes every commit fail**. Provision the trusted signer
   set explicitly and **pin it** (root-owned): an SSH allowed-signers file
   (`gpg.ssh.allowedSignersFile`) [\[7\]](#ref-7) for SSH-signed commits, or the GPG keyring for GPG-signed
   commits. Pin only the keys you trust to author **control-repository** deploys (it is the control
   repository's branch tip that is verified — the module itself is pinned separately, by `:commit`
   SHA in the Puppetfile); `verify-commit` otherwise accepts *any* key in the trust root.

   For SSH-signed commits, add one line per trusted deploy author to root's allowed-signers
   file — the committer email, then that person's signing public key:

   ```
   echo 'user@example.com ssh-ed25519 AAAA...' | sudo tee -a /root/.ssh/allowed_signers
   ```

   Point root's git at the file (the apply service runs `git verify-commit` as root, so
   root's global git config is what it reads):

   ```
   sudo git config --global gpg.ssh.allowedSignersFile /root/.ssh/allowed_signers
   ```
3. **A merge method that keeps the branch tip signed:** GitLab's default **merge-commit** method
   creates the merge commit **on the server, unsigned** unless instance/project web-commit
   signing is configured, so the tip of the protected branch would fail `verify-commit` even
   when every contributor signs. Use the **fast-forward** merge method (no server merge commit;
   the tip stays your signed commit) [\[8\]](#ref-8), or enable GitLab's web-commit signing
   [\[9\]](#ref-9), so the branch tip is always verifiable.

### Supervision

The loop also hardens the liveness healthcheck that `standalone.manage` installs: with the loop
on, the healthcheck additionally asserts that the apply timer is enabled and armed, that the
checkout is not stale against the remote (a dead pull credential fails loud instead of leaving
the host applying old code behind a green timer), and that the bootstrap gems (`r10k`,
`hiera-eyaml`) are present in the AIO Ruby. A failed assertion leaves the healthcheck unit in
the failed state, visible in `systemctl list-units --failed` and the journal.

### Rolling back a commit

The self-update loop applies whatever signed commit sits at the tip of the protected branch, so a
rollback is an ordinary git operation on the control repository, not a host action.

Revert on the control repository, then merge it the same reviewed, signed way as any change:

```
git revert <bad-sha>
```

The next apply tick fetches, verifies the signature on the new tip, resets to it, and applies, which
converges the host back. Because the loop **verifies before it mutates**, an unsigned or
unverifiable revert never applies: the revert must be signed and reach the branch tip through the
same merge-method constraint as any other change (above).

Two behaviors here are deliberate, not bugs:

- **Freshness over availability:** If the fetch or `verify-commit` fails — dead pull credential,
  unsigned tip, unreachable origin — the apply halts rather than applying stale or unverified
  state, and the healthcheck's staleness check turns a silently stuck host into a failed unit. A
  host that cannot prove it is current stops converging on purpose.
- **Self-modification:** The loop re-applies the very module that defines the apply units, so a
  commit that breaks those units can stop future ticks. Recover by running one apply by hand
  against a fixed commit — it re-lays the units and restarts the loop:

```
sudo systemctl start gitlab-runner-apply.service
```

## References

- <a id="ref-1"></a>\[1\] **Standalone Puppet (`puppet apply`)**: applying manifests directly on a
  node, without a Puppet server.
  [Puppet: `puppet apply`](https://help.puppet.com/core/8/Content/PuppetCore/Markdown/apply.htm)
- <a id="ref-2"></a>\[2\] **r10k**: Puppet control-repository and environment deployment tool.
  [puppetlabs/r10k](https://github.com/puppetlabs/r10k)
- <a id="ref-3"></a>\[3\] **systemd timers**: systemd's mechanism for scheduling unit activation, an
  alternative to cron.
  [systemd.timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)
- <a id="ref-4"></a>\[4\] **OpenVox**: the community fork of Puppet that runs on the host.
  [OpenVox](https://github.com/OpenVoxProject/openvox)
- <a id="ref-5"></a>\[5\] **SSH deploy key**: a read-only, project-scoped key for fetching a
  repository. [GitLab: deploy keys](https://docs.gitlab.com/user/project/deploy_keys/)
- <a id="ref-6"></a>\[6\] **`git verify-commit`**: verifies a commit's GPG/SSH signature.
  [git-verify-commit](https://git-scm.com/docs/git-verify-commit)
- <a id="ref-7"></a>\[7\] **Allowed-signers file**: the `allowed_signers` format SSH signature
  verification reads. [ssh-keygen(1) — ALLOWED SIGNERS](https://man.openbsd.org/ssh-keygen.1#ALLOWED_SIGNERS)
- <a id="ref-8"></a>\[8\] **GitLab merge methods**: fast-forward vs merge-commit, and their effect
  on history. [GitLab Docs — Merge methods](https://docs.gitlab.com/user/project/merge_requests/methods/)
- <a id="ref-9"></a>\[9\] **Signed commits from the GitLab UI**: instance/project web-commit
  signing. [GitLab Docs](https://docs.gitlab.com/user/project/repository/signed_commits/web_commits/)
