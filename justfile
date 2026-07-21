# Check gate for the module — the single definition of the commands.
# Contributors and CI run the same recipes; see CONTRIBUTING.md.
# Ruby tool versions are pinned by Gemfile.lock (run `bundle install` once).

# bare `just` lists the recipes instead of running anything
[private]
default:
    @just --list

# entry banner: tool versions and locations (called by the flake shellHook).
# Binaries report live --version; the bundled Ruby tools (puppet, puppet-lint,
# rspec-puppet) are read from Gemfile.lock — parsing beats `bundle exec
# <tool> --version`, which pays seconds of bundler startup per tool.
[private]
welcome:
    #!/usr/bin/env bash
    set -euo pipefail
    # ETH Zurich brand blue; 256-colour fallback for terminals without truecolor
    if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
        ETH_BLUE_LIGHT=$'\033[38;2;33;92;175m'   # #215CAF — primary ETH blue
        ETH_BLUE_DARK=$'\033[38;2;74;142;212m'   # #4A8ED4 — lighter tint
    else
        ETH_BLUE_LIGHT=$'\033[38;5;25m'
        ETH_BLUE_DARK=$'\033[38;5;75m'
    fi
    RESET=$'\033[0m'
    # column accents: versions match the blue `just --list` uses for recipe
    # comments; locations are muted. Plain ANSI, so no truecolor fallback.
    VERSION_BLUE=$'\033[34m'
    PATH_GREY=$'\033[90m'
    # Light/dark background: COLORFGBG="fg;bg" (bg=15 → light); Apple Terminal
    # defaults to a white background when COLORFGBG is unset.
    if [[ "${COLORFGBG:-}" == *";15" || ( -z "${COLORFGBG:-}" && "${TERM_PROGRAM:-}" == "Apple_Terminal" ) ]]; then
        BANNER_COLOR="$ETH_BLUE_LIGHT"
    else
        BANNER_COLOR="$ETH_BLUE_DARK"
    fi
    # NO_COLOR (https://no-color.org): strip SGR escapes instead of keeping a
    # second uncoloured banner — single source of truth.
    if [[ -n "${NO_COLOR:-}" ]]; then
        emit() { sed $'s/\x1b\\[[0-9;]*m//g'; }
    else
        emit() { cat; }
    fi
    echo ""
    # banner lines are hand-aligned (45 chars between the corners); colour is
    # applied around whole lines so padding never has to count escape codes
    { printf '  %s╭─ ◆ rootless_gitlab_runner ── Puppet module ─╮%s\n' "$BANNER_COLOR" "$RESET"
      printf '  %s│            Nix development shell            │%s\n' "$BANNER_COLOR" "$RESET"
      printf '  %s╰─────────────────────────────────────────────╯%s\n' "$BANNER_COLOR" "$RESET"
    } | emit
    echo ""
    echo "  Tools"
    for tool in ruby bundler just yamllint; do
        if command -v "$tool" >/dev/null 2>&1; then
            version=$("$tool" --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
            : "${version:=unknown}"
            location=$(command -v "$tool")
        else
            version="not found"
            location=""
        fi
        # colours passed as their own %s so %-10s pads the bare version.
        # %-17s starts versions at column 23, flush with the `just --list`
        # comments below (set by the longest signature, `lint target="all"`);
        # re-tune if a longer recipe signature ever appears
        printf '    %-17s %s%-10s%s%s%s%s\n' \
            "$tool" "$VERSION_BLUE" "$version" "$RESET" "$PATH_GREY" "$location" "$RESET"
    done | emit
    if bundle check >/dev/null 2>&1; then
        gems_installed=yes
        # ask bundler where the gems live rather than hardcoding the path
        gem_location=$(bundle config get path --parseable | cut -d= -f2-)
        case "$gem_location" in
            "") gem_location="installed" ;;   # no path configured: default gem home
            /*) ;;                            # absolute path: show as reported
            *)  gem_location="./$gem_location" ;;
        esac
    else
        gems_installed=no
        gem_location="not installed"
    fi
    for gem in puppet puppet-lint rspec-puppet; do
        version=$(awk -v g="$gem" '$1 == g && $2 ~ /^\([0-9]/ { gsub(/[()]/, "", $2); print $2; exit }' Gemfile.lock)
        printf '    %-17s %s%-10s%s%s%s%s\n' \
            "$gem" "$VERSION_BLUE" "${version:-unknown}" "$RESET" "$PATH_GREY" "$gem_location" "$RESET"
    done | emit
    echo ""
    if [[ "$gems_installed" == no ]]; then
        echo "  Setup needed: just install"
        echo ""
    fi
    just --list --list-heading $'  Commands\n' --list-prefix '    '
    echo ""

# install the Ruby tools pinned by Gemfile.lock; run on first setup and after the lock changes
install:
    bundle config set --local path vendor/bundle
    bundle install

# run all checks: validate, lint, test, docs
check: validate lint test _docs-check

# syntax-check every Puppet manifest and EPP template without applying anything.
# ./.claude/ holds agent worktrees (full checkouts): sweeping them in redefines
# every type and template, so the validate walk must skip the directory.
validate:
    find . -name '*.pp' -not -path './vendor/*' -not -path './spec/fixtures/*' \
        -not -path './.claude/*' \
        -print0 | xargs -0 -r bundle exec puppet parser validate
    find . -name '*.epp' -not -path './vendor/*' -not -path './spec/fixtures/*' \
        -not -path './.claude/*' \
        -print0 | xargs -0 -r bundle exec puppet epp validate

# lint everything (the default), or one target: `just lint < puppet | metadata | yaml | nix >`
lint target="all":
    @just _lint-{{ target }}

_lint-all: _lint-puppet _lint-yaml _lint-metadata _lint-nix

# style and correctness lint of the manifests (warnings fail too: .puppet-lint.rc)
_lint-puppet:
    bundle exec puppet-lint --ignore-paths 'vendor/*,spec/*' manifests

# metadata.json schema/style lint (name pattern, SPDX license, dep ranges)
_lint-metadata:
    bundle exec metadata-json-lint metadata.json

# lint all YAML in the repo (rules in .yamllint)
_lint-yaml:
    yamllint .

# check the repo's Nix files are formatted (treefmt + nixfmt, from the dev
# shell). A failure reformats the files in place: review and stage them.
# `nix fmt` applies the same formatting on demand. Outside the dev shell
# (the without-Nix path) treefmt is unavailable: skip with a notice rather
# than fail — the check still runs in CI and on every dev-shell commit.
_lint-nix:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v treefmt >/dev/null 2>&1; then
        echo "lint nix: treefmt not on PATH (outside the dev shell); skipping the Nix format check." >&2
        exit 0
    fi
    treefmt --fail-on-change

# rspec-puppet unit tests, including the golden-file render check
test: _fixtures
    bundle exec rspec

# regenerate REFERENCE.md from the manifests' puppet-strings docs
docs:
    bundle exec puppet strings generate --format markdown --out REFERENCE.md

# fail when REFERENCE.md is stale relative to the manifests
[private]
_docs-check:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    echo "docs-check: regenerating REFERENCE.md from the manifests' puppet-strings docs into a temp file..."
    bundle exec puppet strings generate --format markdown --out "$tmp" >/dev/null 2>&1
    echo "docs-check: comparing the current REFERENCE.md against the freshly generated docs..."
    if diff -u REFERENCE.md "$tmp"; then
        echo "docs-check: PASS - the current REFERENCE.md matches the manifests; nothing to regenerate."
    else
        echo "docs-check: FAIL - the diff above shows how the current REFERENCE.md differs from the manifests." >&2
        echo "docs-check: run 'just docs' to regenerate REFERENCE.md, then commit the regenerated file with your change." >&2
        exit 1
    fi

# fetch the spec fixture modules (apt, stdlib) pinned in .fixtures.yml
[private]
_fixtures:
    bundle exec puppet-fixtures install

# re-record assets/dev-shell.gif, the scripted shell entry shown in
# CONTRIBUTING.md; run it whenever the banner or the command list changes.
[private]
record-demo:
    #!/usr/bin/env bash
    set -euo pipefail
    # repo-local scratch dir (gitignored), so nothing is written outside the
    # repository; removed on exit, so it survives only a crash
    scratch="$PWD/.record-demo"
    rm -rf "$scratch" && mkdir "$scratch"
    trap 'rm -rf "$scratch"' EXIT
    # the typed-entry script simulates typing `nix develop` inside the recorded
    # terminal. It must be a file: it runs three shells deep (nix shell →
    # bash -c → asciinema -c), and a file spares escaping quotes at every layer
    cat > "$scratch/typed-entry.sh" <<'TYPED_ENTRY'
    # the GIF theme is light; tell the banner so it picks the darker blue
    export COLORFGBG='0;15'
    cmd='nix develop'
    printf '\033[1;32m❯\033[0m '
    sleep 0.8
    for ((i = 0; i < ${#cmd}; i++)); do printf '%s' "${cmd:i:1}"; sleep 0.07; done
    sleep 0.5
    printf '\n'
    # nix's "Git tree is dirty" stderr warning would clutter the recording
    nix develop --command true 2> >(grep -v "Git tree .* is dirty" >&2)
    sleep 0.5
    printf '\033[1;32m❯\033[0m '
    sleep 2.5
    TYPED_ENTRY
    # agg's github-light palette (bg,fg,16 ANSI colours) with the background
    # forced to pure white, so the GIF blends into the markdown page instead
    # of sitting in an off-white (#eceff4) box
    theme='ffffff,171b21,0e1116,f97583,a2fca2,fabb72,7db4f9,c4a0f5,1f6feb,eceff4,6a737d,bf5a64,7abf7a,bf8f57,608bbf,997dbf,195cbf,b9bbbf'
    # 120 cols fits the longest `just --list` line; 24 rows fits the session
    # exactly. font-size 11 keeps the GIF narrower than the rendered page, so
    # markdown viewers show it at natural size without any HTML sizing attributes
    nix develop .#demo --command bash -c \
        "asciinema rec --cols 120 --rows 24 -q --overwrite -c 'bash $scratch/typed-entry.sh' $scratch/dev-shell.cast \
         && agg --theme $theme --font-size 11 $scratch/dev-shell.cast assets/dev-shell.gif"
