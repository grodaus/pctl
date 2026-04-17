{yants}: let
  inherit (yants) struct list string attrs option enum;

  limits = struct "limits" {
    memoryMax = option string;
    cpuQuota = option string;
  };
in {
  inherit limits;
  service = struct "service" {
    command = list string;
    env = option (attrs string);
    dependsOn = option (list string);
    restart = option (enum "restart" ["no" "on-failure" "always" "on-abnormal"]);
    limits = option limits;
    serviceConfig = option (attrs string);
  };
}
