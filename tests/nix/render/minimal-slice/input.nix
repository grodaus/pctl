{
  projectId = "@@PROJECT@@";
  services = {};
  expected = {
    "pctl-@@PROJECT@@.slice" = ''
      [Unit]
      Description=pctl project @@PROJECT@@

      [Slice]
    '';
  };
}
