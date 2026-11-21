_: {
  config = {
    programs = {
      actionlint.enable = true;
      deadnix.enable = true;
      jsonfmt.enable = true;
      just.enable = true;
      nixfmt.enable = true;
      statix.enable = true;
      # Configured by stylua.toml.
      stylua.enable = true;
      taplo.enable = true;
      typos.enable = true;
      yamlfmt.enable = true;
    };
    projectRootFile = "flake.nix";
    settings.formatter = {
      typos.excludes = [
        "*.avif"
        "*.bmp"
        "*.gif"
        "*.jpeg"
        "*.jpg"
        "*.png"
        "*.svg"
        "*.tiff"
        "*.webp"
        ".vscode/settings.json"
      ];
    };
  };
}
