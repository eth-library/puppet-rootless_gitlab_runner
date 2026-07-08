{
  description = "Dev shell for the rootless_gitlab_runner Puppet module";

  inputs = {
    # A single nixpkgs pin serves local development and CI, and flake.lock
    # fixes the exact revision. The Ruby tools layered on top are pinned
    # separately by Gemfile.lock.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Linux covers CI and the runner hosts; Darwin covers local macOS work.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      # Builds one attribute per system, so devShells.x86_64-linux.default,
      # devShells.aarch64-darwin.default, etc. all exist. The function `f`
      # receives that system's nixpkgs package set.
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "rootless-gitlab-runner-dev";

          packages = [
            # Tools for the `just check` gate. The Ruby tools themselves
            # (puppet, puppet-lint, rspec-puppet) are deliberately not
            # provided here: they come from the Gemfile via bundler, so
            # Gemfile.lock stays their single source of truth.
            pkgs.yamllint # YAML lint (rules in .yamllint)
            pkgs.shellcheck # lints the two rendered shell scripts in the test suite
            pkgs.just # task runner; the justfile defines the gate recipes
            # treefmt pre-configured with nixfmt: `just lint nix` runs it in
            # check mode; `nix fmt` (the formatter output below) applies it.
            pkgs.nixfmt-tree

            # Runtime for the Ruby toolchain. Ruby 3.3 rather than 3.4:
            # puppet 8.10 still expects stdlib gems that ruby 3.4 removed
            # (e.g. syslog). Bundler ships with ruby itself.
            pkgs.ruby_3_3
            # Needed to build native-extension gems in the test bundle
            # (fiddle links against libffi).
            pkgs.libffi
            pkgs.pkg-config
          ];

          shellHook = ''
            # Point git at the hooks tracked in the repo (.githooks/, e.g. the pre-commit gate).
            # This writes to the local .git/config, which is harmless to repeat on every shell
            # entry. It stays outside the interactive guard below because direnv and CI also
            # need the hooks active, and they enter this shell non-interactively. Guarded on a
            # work tree so `nix develop` on a tarball or outside a repo does not fail here.
            if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
              git config core.hooksPath .githooks
            fi

            # The interactive guard: [ -t 1 ] is true only when stdout is a terminal, so the
            # banner (defined in the justfile) shows in interactive shells but stays silent
            # for direnv loads and CI's `nix develop --command`.
            if [ -t 1 ]; then
              just welcome
            fi
          '';
        };

        # `just record-demo` only: asciinema + agg pinned by flake.lock, kept out
        # of the default shell so contributors do not pay for them on every entry.
        demo = pkgs.mkShell {
          name = "rootless-gitlab-runner-demo";
          packages = [
            pkgs.asciinema # screen recorder (`asciinema rec`)
            pkgs.asciinema-agg # renders the .cast to a GIF (`agg`)
          ];
        };
      });

      # `nix fmt` formats the Nix files in the repo. nixfmt-tree is treefmt
      # pre-configured with nixfmt; plain nixfmt only reads stdin when
      # `nix fmt` invokes it without arguments.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
