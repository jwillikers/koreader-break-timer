{ pkgs, treefmtEval, ... }:
{
  src = ./.;
  hooks = {
    check-added-large-files.enable = true;
    check-case-conflicts.enable = true;
    check-executables-have-shebangs.enable = true;

    check-format = {
      enable = true;
      entry = "${treefmtEval.config.build.wrapper}/bin/treefmt --fail-on-change";
      # Parallel treefmt processes time out waiting on each other's cache database.
      require_serial = true;
    };

    check-json.enable = true;
    check-shebang-scripts-are-executable.enable = true;
    check-symlinks.enable = true;
    check-toml.enable = true;
    check-yaml.enable = true;
    detect-private-keys.enable = true;
    editorconfig-checker.enable = true;
    end-of-file-fixer.enable = true;
    fix-byte-order-marker.enable = true;
    forbid-new-submodules.enable = true;
    # todo Enable lychee when asciidoc is supported.
    # See https://github.com/lycheeverse/lychee/issues/291
    # lychee.enable = true;
    luacheck.enable = true;
    mixed-line-endings.enable = true;
    nil.enable = true;

    strip-location-metadata = {
      name = "Strip location metadata";
      description = "Strip geolocation metadata from image files";
      enable = true;
      entry = "${pkgs.exiftool}/bin/exiftool -duplicates -overwrite_original '-gps*='";
      package = pkgs.exiftool;
      types = [ "image" ];
    };

    tests = {
      name = "Unit tests";
      description = "Run the unit tests with LuaJIT, which KOReader uses";
      enable = true;
      entry = "${pkgs.luajit}/bin/luajit test/test_breaktimer.lua";
      package = pkgs.luajit;
      files = "\\.lua$";
      pass_filenames = false;
    };

    trim-trailing-whitespace.enable = true;
    yamllint.enable = true;
  };
}
