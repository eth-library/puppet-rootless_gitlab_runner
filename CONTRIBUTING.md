# Contributing

This document covers how to contribute to this module: setting up the development
environment, running the checks, the layout of the code, and how changes are reviewed,
merged and deployed. Consuming and operating the module on a host is covered by the
[README](README.md).

## Table of contents

- [Development toolchain](#development-toolchain)
- [Development environment](#development-environment)
  - [With Nix (recommended)](#with-nix-recommended)
  - [Without Nix](#without-nix)
  - [Verify the setup](#verify-the-setup)
- [Command reference](#command-reference)
- [How the module is put together](#how-the-module-is-put-together)
  - [Walkthrough: adding a configuration option](#walkthrough-adding-a-configuration-option)
- [Testing](#testing)
- [Change workflow](#change-workflow)
- [Branching strategy](#branching-strategy)
- [Commit rules](#commit-rules)
- [CI/CD](#cicd)
- [Releases](#releases)
- [References](#references)

## Development toolchain

`rootless_gitlab_runner` is a Puppet module that installs and manages a rootless
GitLab Runner host; the [README](README.md) describes what it does in operation. The
code consists of Puppet manifests and EPP templates. The tooling around it comes from
the Ruby ecosystem, because Puppet is written in Ruby: the `puppet` CLI validates
syntax, `puppet-lint` enforces style, and `rspec-puppet` runs the unit tests, all
installed by Bundler at the versions pinned in `Gemfile.lock`. A Nix dev shell
provides the remaining tools (Ruby, yamllint, just) at the versions pinned in
`flake.lock`, and the `justfile` defines the check commands, so the same checks run
identically on every machine and in CI. The table below groups each tool by role; every
one is explained again where it is used.

| Tool | Category | Purpose | How this module uses it |
|---|---|---|---|
| **Puppet** [\[1\]](#ref-1) | Configuration management | Declarative configuration management: you describe the target state, Puppet converges a host to it | `manifests/*.pp` hold the module logic; the `puppet` CLI also syntax-checks manifests and templates |
| **EPP** [\[2\]](#ref-2) | Templating | Puppet's templating language | `templates/*.epp` render the runner config and the systemd units |
| **Hiera** [\[3\]](#ref-3) | Data lookup | Puppet's hierarchical data lookup, keeping data out of code | consumers feed the module host data as Hiera keys; the class parameters in `init.pp` are that contract |
| **Ruby** [\[13\]](#ref-13) | Language runtime | The programming language Puppet and its tooling are written in | the dev shell provides Ruby 3.3; every Ruby tool below runs on it |
| **Bundler** [\[4\]](#ref-4) | Dependency management | Ruby's dependency manager | `Gemfile` declares the Ruby tools, `Gemfile.lock` pins their exact versions, `bundle exec <tool>` runs them |
| **rspec-puppet** [\[5\]](#ref-5) | Testing | Unit-test framework for Puppet modules | compiles the class and asserts on the result (see [Testing](#testing)) |
| **puppet-lint** [\[6\]](#ref-6) | Linting | Linter enforcing the Puppet style guide [\[7\]](#ref-7) | `just lint puppet`; options in `.puppet-lint.rc` |
| **yamllint** [\[8\]](#ref-8) | Linting | YAML linter | `just lint yaml`; rules in `.yamllint` |
| **shellcheck** [\[22\]](#ref-22) | Linting | Shell-script linter | the unit suite pipes the two rendered shell scripts through it (see [Testing](#testing)) |
| **nixfmt** [\[17\]](#ref-17) | Formatting | Formatter for the Nix language, run across the repository by treefmt | `just lint nix` fails when `flake.nix` is unformatted; `nix fmt` applies the formatting |
| **Nix flakes** [\[9\]](#ref-9) | Environment management | Reproducible package manager; a *flake* pins a complete environment to exact versions | `flake.nix` defines the dev shell, `flake.lock` pins it |
| **direnv** [\[10\]](#ref-10) | Environment management | Loads a per-directory environment automatically | `.envrc` enters the dev shell whenever you `cd` into the repository |
| **just** [\[11\]](#ref-11) | Task automation | A command runner: named recipes for a project's commands | the `justfile` is the single definition of the check gate |
| **GitHub Actions** [\[12\]](#ref-12) | Continuous integration | GitHub's CI/CD system | `.github/workflows/ci.yml` runs the same recipes on pull requests and `main` |

Two lockfiles pin every tool version: `flake.lock` (the environment: Ruby, yamllint,
just) and `Gemfile.lock` (the Ruby tools: puppet, puppet-lint, rspec-puppet). CI enters
the same dev shell and runs the same `just` recipes, split across three independent
jobs (see [CI/CD](#cicd)); the shared lockfiles prevent version drift between CI and
local development environments.

## Development environment

Two supported paths. The Nix path is recommended: it installs nothing globally and
cannot drift from CI. The manual path installs a few tools by hand and then runs the
identical commands.

### With Nix (recommended)

> [!TIP]
> **Using the Nix shell for development is strongly recommended**, for a few reasons: it pins
> the entire toolchain — Ruby, Puppet, the linters and `just` — to exact versions in
> `flake.lock`; every contributor and the CI/CD pipeline then run the same; and it
> activates the git pre-commit hook automatically.

**Prerequisite:** Nix is installed and the `nix-command` and `flakes` features are
enabled. See [Install Nix](https://nixos.org/download/) and the flakes
documentation [\[9\]](#ref-9) for how.

**Step 1, enter the dev shell.** Two ways:

- With direnv [\[10\]](#ref-10): run `direnv allow` once. Afterwards the shell loads
  automatically whenever the repository directory is entered; `nix develop` is never run
  manually.

  ```
  direnv allow
  ```

- Without direnv: enter the shell manually, in each terminal session:

  ```
  nix develop
  ```

The first entry downloads the toolchain pinned by `flake.lock`; later entries reuse
it. On entry the shell prints the tool versions and locations and the available
`just` commands:

![Entering the dev shell: the banner, the tool versions and locations, and the available just commands](assets/dev-shell.gif)

The recording is illustrative — the pinned versions move on; the printout on a real
entry is authoritative.
<!-- To re-record assets/dev-shell.gif after the banner or the `just` command
     list changes, run the hidden `just record-demo` recipe. -->

**Step 2, install the Ruby tools.**

```
just install
```

`just install` runs `bundle install`, which installs the gem versions pinned by
`Gemfile.lock` (puppet, puppet-lint, rspec-puppet and their dependencies) into
`vendor/bundle/` inside the repository; nothing is installed globally. This is needed
once after cloning, and again after every `Gemfile.lock` change.

### Without Nix

The Nix path above is the simplest and most reliable way to a working environment. The
manual path is a fallback and needs more steps: everything the Nix development shell provides
— Ruby, the linters, `just` — is installed by hand, and some of the Ruby test tools
additionally compile native extensions that need a system build environment.

Install by hand what the Nix development shell would have provided. Each linked reference
covers its own installation; match the versions `flake.lock` pins where it matters:

1. **A supported Ruby with Bundler** [\[13\]](#ref-13). The module is tested on **Ruby 3.3**
   (the version the Nix shell pins); the Gemfile constrains `>= 3.3.0, < 3.4.0`, so
   `bundle install` fails fast on other versions. Bundler ships with Ruby.
2. **A C build environment**, so `bundle install` can compile the native-extension gems in
   the bundle — such as `fiddle` [\[24\]](#ref-24) (a `libffi` [\[25\]](#ref-25) wrapper,
   pulled in transitively). This is standard for Ruby gems with C extensions and the packages
   vary by OS, so rather than reproduce a per-OS list here, install what the platform needs
   from ruby-build's "Suggested build environment" [\[23\]](#ref-23), which covers the
   compiler and libraries across macOS, Debian/Ubuntu, Fedora, Arch and more.
3. **yamllint** [\[8\]](#ref-8): the YAML linter (`just lint yaml`).
4. **shellcheck** [\[22\]](#ref-22): the unit suite lints the module's rendered shell scripts
   with it.
5. **just** [\[11\]](#ref-11), strongly recommended — packaged for most platforms
   [\[14\]](#ref-14). The recipes are the intended way to run the gate, though each is a thin
   wrapper around plain commands (see the [`justfile`](justfile)) that can be run directly.

Then `just install` from the repository root (without just:
`bundle config set --local path vendor/bundle && bundle install`). puppet, puppet-lint
and rspec-puppet come from `Gemfile.lock` via Bundler, exactly as on the Nix path.

One check does not run on this path: the Nix format check (`just lint nix`) needs treefmt
from the Nix development shell, so `just check` skips it here with a notice. CI and commits
made from the Nix development shell still run it.

### Verify the setup

Run the full gate by executing:

```
just check
```

On a healthy setup every step passes and the run exits 0. With the tools above installed, no
step should be skipped.

## Command reference

The [`justfile`](justfile) is the single definition of the project's commands. Bare
`just` lists the recipes:

| Recipe | What it does |
|---|---|
| `just check` | **runs every check below, in order**: `validate`, the linters, `test`, plus a [`REFERENCE.md`](REFERENCE.md) freshness check. The full local gate; run it before pushing |
| `just docs` | regenerates [`REFERENCE.md`](REFERENCE.md) from the manifests' puppet-strings (`@param`) docs — run it after changing parameters; `just check` fails when it is stale |
| `just install` | `bundle install`: the Ruby tools from [`Gemfile.lock`](Gemfile.lock), into `vendor/bundle` |
| `just lint` | every `lint` target below |
| `just lint metadata` | `metadata-json-lint` on [`metadata.json`](metadata.json): schema, name pattern, SPDX license, dependency ranges |
| `just lint nix` | checks the repository's Nix files are formatted (treefmt + nixfmt). A failure reformats them in place: review and stage the result. `nix fmt` applies the same formatting on demand |
| `just lint puppet` | `puppet-lint` on the manifests: style and correctness. Warnings fail too ([`.puppet-lint.rc`](.puppet-lint.rc)) |
| `just lint yaml` | `yamllint` across the repository's YAML |
| `just test` | fetches the fixture modules pinned in [`.fixtures.yml`](.fixtures.yml) (apt, stdlib), then runs the rspec-puppet unit tests (see [Testing](#testing)) |
| `just validate` | `puppet parser validate` on every manifest and `puppet epp validate` on every template: pure syntax checks, nothing is applied to any host |
| `just _docs-check` | private (hidden from `just --list`); the [`REFERENCE.md`](REFERENCE.md) freshness check — regenerates to a temp file and diffs it against the committed one. Run by `just check` and CI |
| `just _fixtures` | private (hidden from `just --list`); fetches the spec fixture modules pinned in [`.fixtures.yml`](.fixtures.yml). Run by `just test` (and CI's `puppet-unit` job) before rspec |

CI runs these same recipes, but not via `just check`: each of the three pipeline jobs
runs its own slice independently (see [CI/CD](#cicd)). Together the jobs cover exactly
what `just check` covers.

A git **pre-commit hook** (`.githooks/pre-commit`) runs `just check` before every
commit — the gate is fast enough that nothing is skipped. Entering the dev shell activates it
automatically (the flake shellHook sets
`git config core.hooksPath .githooks`); on the without-Nix path, run that `git config`
command once yourself. Committing from outside the dev shell still works: the hook
falls back to `nix develop --command just check`. Skip it for a single commit with
`git commit --no-verify` — CI runs the same checks regardless.

## How the module is put together

One public class, `rootless_gitlab_runner` (in `manifests/init.pp`), declares every
parameter and contains seven private classes, one per concern, in a fixed order:
apt repositories, packages, user, rootless-docker bring-up, config, service,
self-update. Data flows one
way: the consumer's Hiera data binds to the class parameters, `init.pp` derives shared
values (runtime paths, the exec environment contract), and the private classes render
templates and declare resources from them. Private classes refuse direct inclusion;
the public class is the only entry point.

```
.
├── manifests/                    # Puppet classes (the logic)
│   ├── init.pp                   #   public class: parameters, ordering, containment
│   ├── apt_repos.pp              #   apt repositories behind manage_apt_repos
│   ├── packages.pp               #   apt packages from the `packages` list
│   ├── user.pp                   #   runner user, home, subordinate IDs
│   ├── rootless_docker.pp        #   rootless-docker bring-up behind the preflight
│   ├── config.pp                 #   renders config.toml; secret-store directory
│   ├── service.pp                #   runner service + privilege-drop drop-in
│   └── self_update.pp            #   self-update loop + healthcheck units
├── templates/                    # EPP templates rendered onto the host
│   ├── config.toml.epp           #   the runner config, from the Hiera runners list
│   ├── service-dropin.conf.epp   #   privilege drop + environment for the service
│   └── ...                       #   apply/healthcheck scripts, services, timers
├── files/
│   └── no-detach-netns.conf      # rootless-docker drop-in (the incident fix)
├── hiera.yaml                    # module data layer
├── data/
│   └── common.yaml               #   lookup_options: convert_to Sensitive for the token store
├── examples/                     # standalone consumer skeleton (flat); data drift-gated in spec
│   ├── README.md                 #   layout + wrapper-repository assembly note
│   ├── data/                     #   the runner config as class params (common.yaml + node)
│   ├── hiera.yaml                #   standalone hierarchy (datadir: data, sits beside data/)
│   ├── site.pp                   #   standalone entry: include rootless_gitlab_runner
│   ├── Puppetfile                #   r10k pinning for the masterless wrapper repository
│   └── secrets.example.yaml      #   off-repository token-store template (never committed)
├── spec/
│   ├── classes/                  # rspec-puppet tests (catalog + golden files)
│   ├── fixtures/golden/          # committed expected renders (config.toml + shell scripts)
│   └── fixtures/modules/         # module symlink + fetched fixtures (.fixtures.yml)
├── .github/workflows/ci.yml      # CI: same shell, same recipes (see CI/CD)
├── .github/dependabot.yml        # weekly grouped updates: actions, gems, flake inputs
├── metadata.json                 # module name, version, supported OS + Puppet range
├── Gemfile, Gemfile.lock         # Ruby tools, exact-pinned          ─┐ the two
├── flake.nix, flake.lock         # dev-shell environment, exact-pinned ┘ lockfiles
├── justfile                      # the check gate, single definition
├── .githooks/pre-commit          # pre-commit gate: just check (activated on dev-shell entry)
├── .envrc                        # direnv: enter the dev shell automatically
├── .puppet-lint.rc               # --relative: module layout at the repository root
├── .yamllint                     # yamllint rules
└── .rspec                        # rspec defaults (output format, spec pattern)
```

The module keeps its **dependency surface deliberately small**: built-in Puppet
resource types wherever possible, plus two Forge modules — `puppetlabs/stdlib`
(the `assert_private()` guard in the internal classes) and `puppetlabs/apt` (the
apt sources behind `manage_apt_repos`).

### Walkthrough: adding a configuration option

As a practical example, exposing a new `config.toml` key:

1. **`templates/config.toml.epp`**: render the key from the runner hash.
2. **`manifests/init.pp`**: document it in the `runners` `@param` list (the class
   parameters are the module's public API; their doc comments are the API docs).
3. **`spec/classes/rootless_gitlab_runner_spec.rb`**: assert the rendered line, and
   update `spec/fixtures/golden/config.toml.golden` to the new expected output. The
   golden file is updated by hand, deliberately: its diff is the review surface for
   template changes, so never regenerate it unseen.
4. **`README.md`**: only if the consumer-facing contract changed (new Hiera key,
   changed default).
5. Run `just check` to run all checks before you commit.

## Testing

The unit tests are rspec-puppet [\[5\]](#ref-5): each example compiles the class, with
a given set of parameters on the supported OS, into a *catalog* (Puppet's resolved
list of resources) and asserts on it. No host is involved; a test failure means the
module would have declared the wrong state. The suite covers the parameter guards (the
fail-loud cases), the resources behind each `manage_*` toggle, and the service
postures.

A few pieces are worth knowing beyond the plain parameter-and-guard examples:

- **Fixtures:** `just test` first runs `puppet-fixtures install`, which fetches the
  module dependencies pinned in [`.fixtures.yml`](.fixtures.yml) (apt, stdlib) into
  `spec/fixtures/modules/` and symlinks this module in beside them, so rspec-puppet can
  compile catalogs that `include apt`. The fetched fixtures are gitignored; the pins in
  `.fixtures.yml` are the source of truth.
- **Golden-file tests:** Rather than assert on fragments, these render an artifact in
  full and compare it byte for byte against a committed expected file under
  `spec/fixtures/golden/`: `config.toml` for a two-runner scenario, and the two rendered
  shell scripts (the apply and healthcheck scripts). Any template change surfaces as a
  diff in the golden — that diff is the review surface, and the golden is updated by hand
  on purpose (see the [walkthrough](#walkthrough-adding-a-configuration-option)). The two
  shell scripts are additionally piped through `shellcheck`; that check is skipped only
  when `shellcheck` is not on `PATH` (it is in the dev shell and in CI).
- **Facts:** Examples that need a compiled catalog use the supported OS's facts, derived
  from `metadata.json` via `on_supported_os` (rspec-puppet-facts), so the fact set tracks
  the module's declared platform support instead of a hand-kept hash.
- **Coverage:** After the suite, rspec-puppet prints a resource-coverage summary — how
  many of the declared resources the examples touched. It is informational, not a gate.

The pipeline is the only gate between a merged commit and the hosts that auto-deploy
it.

## Change workflow

- Keep every change well scoped: one concern per pull request, one logical change per
  commit. A pull request that fixes a bug should not also refactor unrelated code.
- Code and tests move together: a change and the tests covering it belong in the same
  pull request (see [Testing](#testing)).
- Update the documentation the change touches: `@param` docs in `init.pp` for API
  changes, the README when the consumer-facing contract changes.
- Record consumer-facing changes in `CHANGELOG.md` under `## [Unreleased]`, in the same
  pull request (new parameters, changed behavior, fixes, dependency or platform changes).
  Internal-only changes (refactors, tests, CI) need no entry.
- Open a **pull request** against `main`; merging requires a green validation
  workflow (see [CI/CD](#cicd)).
- Every commit follows the [commit rules](#commit-rules) below.

## Branching strategy

Development is trunk-based [\[21\]](#ref-21): `main` is always releasable, and every change lands on it
through a short-lived topic branch and a pull request — never a direct push (`main` is
protected; see [CI/CD](#cicd)).

- **Topic branches are short-lived** and named for the change with a Conventional-Commit
  type prefix — `feat/allowed-images`, `fix/apply-script-quoting`,
  `docs/contributing-releases`. Branch from the current `main`, open a pull request, merge
  on a green gate, delete the branch.
- **Releases tag `main` directly.** The default release path adds no long-lived branch: a
  release is a signed tag on a `main` commit (see [Releases](#releases)).
- **`release/<version>` branches are optional and rarely needed.** The tag-on-`main` flow
  covers releases without one; a release branch is warranted only in the uncommon case where
  a release must be staged apart from ongoing work — for example holding a version bump and
  CHANGELOG roll while other changes keep landing. It is short-lived and deleted once the tag
  is pushed.

## Commit rules

Repository-wide rules; they apply to every commit on every branch.

- **Commits must be signed** [\[15\]](#ref-15); the repository rejects unsigned
  commits. Signing is also a deployment gate: hosts running the standalone
  self-update loop verify the commit signature (`git verify-commit`) on the remote
  branch before applying it, so an unsigned commit could never deploy anyway.
- **Commit messages follow Conventional Commits** [\[16\]](#ref-16):
  `<type>(<scope>): <summary>`. Keep one logical change per commit. The type carries the
  change's meaning for a configuration module, and drives the version bump at release time
  (see [Releases](#releases)):
  - `feat`: a new parameter, toggle, or managed resource — a **minor** bump.
  - `fix`: a correction to rendered configuration or applied host state — a **patch** bump.
  - `docs`, `test`, `refactor`, `chore`: documentation, specs, no-behaviour-change
    restructuring, and tooling/CI/dependency housekeeping respectively — none drives a
    release on its own.

  Scopes track the private classes and templates (`config`, `service`, `self_update`,
  `apt_repos`, `user`, `rootless_docker`), e.g. `feat(config): render allowed_images`,
  `fix(self_update): quote repo_path in apply script`.
- **Breaking changes are marked explicitly.** Append `!` after the type/scope
  (`feat(init)!: rename the runners key`) or add a `BREAKING CHANGE:` footer that names the
  break and its migration. A breaking change is a **major** bump under the Puppet rule in
  [Releases](#releases): a renamed or removed parameter or Hiera key, a changed
  host-affecting default, or a dropped supported Puppet, Ruby, or operating-system version.

## CI/CD

The GitHub Actions [\[12\]](#ref-12) workflow `.github/workflows/ci.yml` runs the
validation jobs **on pull requests and on pushes to `main`** (and on demand from the
Actions tab). Every job installs Nix,
enters the committed dev shell, and runs its slice of the gate. Three independent
jobs, same recipes as local:

| Job | Runs (inside `nix develop`) |
|---|---|
| `puppet-validate` | `just install`, `just validate`, `just lint puppet`, `just lint metadata`, `just _docs-check` |
| `puppet-unit` | `just install`, `just test` |
| `yaml-lint` | `just lint yaml`, `just lint nix` |

The toolchain comes from `flake.lock` and `Gemfile.lock` in both places, which
prevents version drift between CI and local development environments. Two caches keep
it fast: the Nix store (keyed on the Nix files plus `flake.lock`) and the installed gems
(keyed on `flake.lock` plus `Gemfile.lock`, so a Ruby-series bump re-installs cleanly
instead of restoring an ABI-mismatched [\[18\]](#ref-18) bundle).

The workflow runs least-privilege (`permissions: contents: read`, no persisted checkout
token), and its action versions are SHA-pinned. Dependabot (`.github/dependabot.yml`)
keeps those pins, the Ruby gems, and the Nix flake inputs current, opening a grouped PR
per ecosystem each week that goes through the same gate as any other change.

These checks never touch a host; they validate code only, so they run on plain hosted
runners. Keeping them green is what makes protecting `main`, and therefore the
auto-deploy described in the README's
[Applying the configuration](README.md#applying-the-configuration), safe: a red check
is the last cheap place to catch a bad change before a host converges to it.

A separate workflow, `.github/workflows/release.yml`, runs at release time rather than on
every change: a pushed `v*` tag triggers it to guard the tag against `metadata.json` and the
CHANGELOG, reuse the validation workflow above as its gate, and draft a GitHub Release for
a maintainer to publish (see [Releases](#releases)). It never creates, signs, or publishes
the tag.

## Releases

Versions follow Semantic Versioning [\[19\]](#ref-19), read for a configuration module: a
**breaking change** — one that can break a consumer's existing data or platform — is a
**major** bump. That covers renaming or removing a parameter or Hiera key, changing a
host-affecting default, and dropping a supported Puppet, Ruby, or operating-system version.
A new parameter, toggle, or managed resource is a **minor** bump; a correction to rendered
configuration or applied state is a **patch** bump.

The flow keeps a maintainer at both trust anchors — signing the tag and publishing the
release — while CI does the mechanical validation and drafting in between:

1. **Land the change on `main`** through a pull request, with its `CHANGELOG.md` entry under
   `## [Unreleased]` (see [Change workflow](#change-workflow) and
   [Commit rules](#commit-rules)).
2. **Roll the CHANGELOG and bump the version** in a short-lived pull request: rename
   `## [Unreleased]` to `## [<version>] - <date>` [\[20\]](#ref-20), open a fresh empty
   `## [Unreleased]`, and set `metadata.json` `version` to `<version>`. Merge it on a green
   gate.
3. **Push the signed tag.** On the merge commit, a maintainer pushes an annotated, signed
   `v<version>` tag (`main` requires signed commits; the standalone self-update loop verifies
   the signature before applying — see [Commit rules](#commit-rules)).
4. **CI drafts the Release.** The tag push triggers the release workflow (see
   [CI/CD](#cicd)), which guards the tag against `metadata.json` and the CHANGELOG, reuses
   the validation gate, and creates a **draft** GitHub Release titled `v<version>` with the
   matching CHANGELOG section as its notes. CI never creates, signs, or publishes the tag or
   the release.
5. **A maintainer publishes the draft** in the GitHub UI after a review — the publish click is
   the final confirmation.

Between releases, `metadata.json` `version` carries the next patch with an `-rc0` suffix (for
example `1.0.1-rc0` once `1.0.0` has shipped), marking `main` as unreleased development.

**Forge publishing is not part of a release yet.** The first releases ship git-only (r10k
pins a commit or tag). Publishing to the Puppet Forge may be evaluated for a later version,
once the packaging path is exercised.

## References

- <a id="ref-1"></a>\[1\] **Puppet**: the configuration-management language and CLI;
  this module targets Puppet 8 (see `metadata.json`).
  [Puppet: `puppet apply`](https://help.puppet.com/core/8/Content/PuppetCore/Markdown/apply.htm)
- <a id="ref-2"></a>\[2\] **EPP templates**: the Embedded Puppet templating language
  used to render files such as the runner config.
  [Puppet: EPP](https://help.puppet.com/core/8/Content/PuppetCore/lang_template_epp.htm)
- <a id="ref-3"></a>\[3\] **Hiera**: Puppet's hierarchical key-value lookup that keeps
  data separate from code.
  [Puppet: Hiera](https://help.puppet.com/core/8/Content/PuppetCore/hiera_intro.htm)
- <a id="ref-4"></a>\[4\] **Bundler**: dependency manager for Ruby; installs and runs
  the exact gem versions in `Gemfile.lock`. [bundler.io](https://bundler.io/)
- <a id="ref-5"></a>\[5\] **rspec-puppet**: unit-testing framework for Puppet modules.
  [puppetlabs/rspec-puppet](https://github.com/puppetlabs/rspec-puppet/)
- <a id="ref-6"></a>\[6\] **puppet-lint**: checks Puppet code against the style guide.
  [puppetlabs/puppet-lint](https://github.com/puppetlabs/puppet-lint/)
- <a id="ref-7"></a>\[7\] **Puppet style guide**: the conventions puppet-lint enforces.
  [Puppet: style guide](https://help.puppet.com/core/8/Content/PuppetCore/style_guide.htm)
- <a id="ref-8"></a>\[8\] **yamllint**: linter for YAML files.
  [yamllint documentation](https://yamllint.readthedocs.io/)
- <a id="ref-9"></a>\[9\] **Nix flakes**: reproducible, lockfile-pinned development
  environments. [nix.dev: flakes](https://nix.dev/concepts/flakes/) ·
  [Install Nix](https://nixos.org/download/) ·
  [NixOS wiki: flakes](https://wiki.nixos.org/wiki/Flakes)
- <a id="ref-10"></a>\[10\] **direnv**: per-directory environment loader.
  [direnv.net](https://direnv.net/)
- <a id="ref-11"></a>\[11\] **just**: a command runner for project-specific recipes.
  [just manual](https://just.systems/man/en/)
- <a id="ref-12"></a>\[12\] **GitHub Actions**: the CI system running the validation
  workflow. [GitHub Actions docs](https://docs.github.com/en/actions)
- <a id="ref-13"></a>\[13\] **Ruby**: the language documentation for the pinned 3.3 series.
  [Documentation for Ruby 3.3](https://docs.ruby-lang.org/en/3.3/)
- <a id="ref-14"></a>\[14\] **Installing just**: package list per platform.
  [just: packages](https://just.systems/man/en/packages.html)
- <a id="ref-15"></a>\[15\] **Signed commits**: cryptographically verifiable commit
  authorship, enforceable per repository.
  [GitHub: commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification)
- <a id="ref-16"></a>\[16\] **Conventional Commits**: the commit-message convention
  used in this repository.
  [conventionalcommits.org](https://www.conventionalcommits.org/en/v1.0.0/)
- <a id="ref-17"></a>\[17\] **nixfmt**: the formatter for Nix code, run repository-wide via
  treefmt (the flake wires both up as `nix fmt`).
  [NixOS/nixfmt](https://github.com/NixOS/nixfmt)
- <a id="ref-18"></a>\[18\] **ABI (application binary interface)**: the binary-level contract
  between compiled code and its runtime; Ruby's native-extension ABI differs across minor
  versions. [Wikipedia](https://en.wikipedia.org/wiki/Application_binary_interface)
- <a id="ref-19"></a>\[19\] **Semantic Versioning**: the `MAJOR.MINOR.PATCH` versioning
  contract this module follows. [semver.org](https://semver.org/spec/v2.0.0.html)
- <a id="ref-20"></a>\[20\] **Keep a Changelog**: the changelog format this module follows,
  including the `## [Unreleased]` convention.
  [keepachangelog.com](https://keepachangelog.com/en/1.1.0/)
- <a id="ref-21"></a>\[21\] **Trunk-Based Development**: the source-control branching model
  this module follows — short-lived branches off a single always-releasable trunk.
  [trunkbaseddevelopment.com](https://trunkbaseddevelopment.com/)
- <a id="ref-22"></a>\[22\] **ShellCheck**: static-analysis linter for shell scripts.
  [shellcheck.net](https://www.shellcheck.net/) ·
  [koalaman/shellcheck](https://github.com/koalaman/shellcheck)
- <a id="ref-23"></a>\[23\] **ruby-build — Suggested build environment**: per-OS packages for
  building Ruby and native-extension gems.
  [rbenv/ruby-build wiki](https://github.com/rbenv/ruby-build/wiki)
- <a id="ref-24"></a>\[24\] **fiddle**: a Ruby library wrapping libffi to call C functions; a
  native-extension gem pulled in transitively by the test tools.
  [ruby/fiddle](https://github.com/ruby/fiddle)
- <a id="ref-25"></a>\[25\] **libffi**: a portable foreign-function-interface C library that
  `fiddle` links against. [sourceware.org/libffi](https://sourceware.org/libffi/)
