{
  description = "Claude usage widget for the macOS native menu bar";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      # Support both Apple Silicon and Intel
      forDarwin = f: nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" ] f;
    in
    {
      # ── Package ───────────────────────────────────────────────────────────────
      packages = forDarwin (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in {
          default = pkgs.stdenv.mkDerivation {
            pname = "claude-usage";
            version = "1.12.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.swift pkgs.swiftpm ];
            buildInputs = with pkgs.darwin.apple_sdk.frameworks; [
              Foundation AppKit SwiftUI Combine
            ];

            buildPhase = ''
              export HOME=$TMPDIR
              swift build -c release 2>&1
            '';

            installPhase = ''
              APP=ClaudeUsage.app
              mkdir -p $out/Applications/$APP/Contents/MacOS
              mkdir -p $out/Applications/$APP/Contents/Resources
              cp .build/release/ClaudeUsage $out/Applications/$APP/Contents/MacOS/
              cp Resources/Info.plist       $out/Applications/$APP/Contents/
              # Ad-hoc sign so Gatekeeper lets it run
              /usr/bin/codesign --force --deep --sign - $out/Applications/$APP || true
            '';

            meta = {
              description = "Native macOS menu bar widget showing Claude.ai usage windows";
              platforms = nixpkgs.lib.platforms.darwin;
            };
          };
        });

      # ── Home-manager module ───────────────────────────────────────────────────
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          pkg = self.packages.${pkgs.stdenv.system}.default;
          appBinary = "${pkg}/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage";
          appBundle  = "${pkg}/Applications/ClaudeUsage.app";
        in
        {
          # Expose the app in ~/Applications so Spotlight and Finder see it
          home.file."Applications/ClaudeUsage.app".source = appBundle;

          # Auto-start as a user LaunchAgent (survives logout/reboot)
          launchd.agents.claude-usage = {
            enable = true;
            config = {
              ProgramArguments   = [ appBinary ];
              RunAtLoad          = true;
              KeepAlive          = true;
              StandardOutPath    = "/tmp/claude-usage.log";
              StandardErrorPath  = "/tmp/claude-usage.log";
            };
          };
        };
    };
}
