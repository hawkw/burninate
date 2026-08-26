{
  description = "burninate breaks your hard drives now so they don't break later";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (top@{ config, withSystem, moduleWithSystem, ... }: {
      imports = [
      ];
      flake = { };
      systems = [
        "aarch64-linux"
        "x86_64-linux"
        # ...
      ];
      perSystem = { config, self', pkgs, ... }: {
        packages.burninate = pkgs.writeShellApplication {
          name = "burninate";
          runtimeInputs = with pkgs; [
            smartmontools # smartctl
            e2fsprogs # badblocks
            util-linux # lsblk, wipefs, blockdev
            coreutils
            gnugrep
            jq # used to parse smartctl -j (JSON) output
          ];
          text = builtins.readFile ./burninate.sh;
        };
        packages.default = self'.packages.burninate;

        checks = {
          # A basic check that the script passes shellcheck, the CLI runs, and
          # prints usage. Building this forces Nix to evaluate the package,
          # so that writeShellApplication runs shellcheck.
          help = pkgs.runCommand "burninate-help" { } ''
            ${self'.packages.burninate}/bin/burninate --help
            touch "$out"
          '';

          # Unit tests for the smartctl-JSON parsing and self-test outcome
          # helpers. See tests/parsing.sh.
          parsing = pkgs.runCommand "burninate-parsing"
            { nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.shellcheck ]; }
            ''
              shellcheck -x -P ${./tests} ${./tests}/common.sh ${./tests}/parsing.sh
              export BURNINATE_LIB=${./burninate.sh}
              export BURNINATE_SAMPLES=${./tests/samples}
              bash ${./tests}/parsing.sh
              touch "$out"
            '';

          # Unit tests for command-line parsing, exit statuses, polling
          # intervals, and tmux pane-command quoting. See tests/cli.sh.
          cli = pkgs.runCommand "burninate-cli"
            { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.shellcheck ]; }
            ''
              shellcheck -x -P ${./tests} ${./tests}/common.sh ${./tests}/cli.sh
              export BURNINATE_LIB=${./burninate.sh}
              bash ${./tests}/cli.sh
              touch "$out"
            '';
        };
      };
    });
}
