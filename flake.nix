{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix2container,
      flake-utils,
    }:
    let
      registry = "ghcr.io/iomu";
      rev = nixpkgs.shortRev;

      tools = {
        wireproxy = {
          pkg = p: p.wireproxy;
        };
      };

      archs = {
        x86_64-linux = "amd64";
        aarch64-linux = "arm64";
      };

      imageName = name: "${registry}/docker-images/${name}";
    in
    flake-utils.lib.eachSystem (builtins.attrNames archs) (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        n2c = nix2container.packages.${system}.nix2container;
        arch = archs.${system};

        caRoot = pkgs.buildEnv {
          name = "cacert-root";
          paths = [ pkgs.cacert ];
          pathsToLink = [ "/etc/ssl" ];
        };
        caLayer = n2c.buildLayer {
          copyToRoot = [ caRoot ];
          deps = [ pkgs.cacert ]; # make sure the symlink targets are in the layer
        };

        # Image tags allow [A-Za-z0-9_.-] only, so replace anything else
        # (e.g. the "+" in "1.2.3+git"), and can't start with "." or "-".
        sanitize = s: lib.replaceStrings [ "+" "~" ":" "/" ] [ "-" "-" "-" "-" ] s;

        # version / base tag per tool (same on every system)
        versionOf = { pkg, ... }: sanitize (lib.getVersion (pkg pkgs));
        baseTag = t: "${versionOf t}-${rev}";

        mkImage =
          name:
          t@{
            pkg,
            exe ? lib.getExe (pkg pkgs),
          }:
          n2c.buildImage {
            name = imageName name;
            tag = "${baseTag t}-${arch}";
            config = {
              entrypoint = [ exe ];
              env = [
                "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
                "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
              ];
            };
            layers = [
              caLayer
              (n2c.buildLayer { deps = [ (pkg pkgs) ]; })
            ];
          };

        images = lib.mapAttrs mkImage tools;
      in
      {
        packages = lib.mapAttrs' (n: img: lib.nameValuePair "image-${n}" img) images;

        apps = {
          # Build and push every image for the current system
          push = {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "push";
                text = lib.concatStringsSep "\n" (
                  lib.mapAttrsToList (n: img: ''
                    echo ">> pushing ${n} (${arch})"
                    ${lib.getExe img.copyToRegistry}
                  '') images
                );
              }
            );
          };

          # Combine the per-arch tags into multi-arch tags
          manifest = {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "manifest";
                runtimeInputs = [ pkgs.crane ];
                text = lib.concatStringsSep "\n" (
                  lib.mapAttrsToList (
                    n: t:
                    let
                      ref = imageName n;
                      base = baseTag t;
                      members = lib.concatMapStringsSep " " (a: "-m ${ref}:${base}-${a}") (lib.attrValues archs);
                    in
                    ''
                      echo ">> manifest ${n} ${base}"
                      ${lib.getExe pkgs.crane} index append -t ${ref}:${base} ${members}
                      ${lib.getExe pkgs.crane} tag ${ref}:${base} ${versionOf t}
                      ${lib.getExe pkgs.crane} tag ${ref}:${base} latest
                    ''
                  ) tools
                );
              }
            );
          };
        };
      }
    );
}
