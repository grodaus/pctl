{yants}: let
  inherit (yants) struct list string attrs option enum int bool;

  limits = struct "limits" {
    memoryMax = option string;
    cpuQuota = option string;
  };

  readinessProbe = struct "readinessProbe" {
    exec = list string;
    periodSeconds = option int;
    timeoutSeconds = option int;
  };

  workspace = struct "workspace" {
    cwd = option bool;
    writable = option bool;
  };
in {
  inherit limits readinessProbe workspace;
  service = struct "service" {
    command = list string;
    env = option (attrs string);
    dependsOn = option (list string);
    restart = option (enum "restart" ["no" "on-failure" "always" "on-abnormal"]);
    limits = option limits;
    serviceConfig = option (attrs string);
    readinessProbe = option readinessProbe;
    workspace = option workspace;
  };
}
