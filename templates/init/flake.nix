{
  description = "a pctl project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pctl.url = "github:grodaus/pctl";
    pctl.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    nixpkgs,
    pctl,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system}.pctl = pctl.lib.${system}.mkProject {
      services = {
        # pctl assigns each project a unique loopback IP as $PCTL_HOST so
        # multiple projects can use the same port without colliding. Refer
        # to it via the systemd-expanded `''${PCTL_HOST}`. Environment= is
        # injected at install time via a drop-in; systemd substitutes in
        # ExecStart at service start.
        web = {
          command = [
            "${pkgs.darkhttpd}/bin/darkhttpd"
            "."
            "--addr"
            "\${PCTL_HOST}"
            "--port"
            "8080"
          ];
        };
      };
    };
  };
}
