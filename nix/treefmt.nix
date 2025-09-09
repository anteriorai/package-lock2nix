{
  programs.nixfmt = {
    enable = true;
    strict = true;
  };
  programs.prettier = {
    excludes = [ "*.md" ];
    enable = true;
    settings.tabWidth = 2;
  };
}
