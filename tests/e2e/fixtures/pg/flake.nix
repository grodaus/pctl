{
  description = "pctl e2e fixture — postgres + dbmate + ruby web";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pctl.url = "path:../../../..";
    pctl.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    nixpkgs,
    pctl,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    pgPort = "15433";
    webPort = "18080";

    migrationsDir = ./db/migrations;

    rubyEnv = pkgs.ruby.withPackages (ps: [ps.pg ps.webrick]);

    pgRun = pkgs.writeShellApplication {
      name = "pctl-pg-run";
      runtimeInputs = [pkgs.postgresql pkgs.coreutils];
      text = ''
        PGDATA="$STATE_DIRECTORY/data"
        SOCKDIR="$RUNTIME_DIRECTORY"

        if [ ! -s "$PGDATA/PG_VERSION" ]; then
          mkdir -p "$PGDATA"
          chmod 0700 "$PGDATA"
          initdb -D "$PGDATA" -U postgres -E UTF8 --auth=trust --no-locale
          {
            echo "listen_addresses = '$PCTL_HOST'"
            echo "port = ${pgPort}"
            echo "unix_socket_directories = '$SOCKDIR'"
            echo "logging_collector = off"
          } >> "$PGDATA/postgresql.conf"
        fi

        if ! test -f "$PGDATA/.app_created"; then
          pg_ctl -D "$PGDATA" -o "-c listen_addresses=''' -c port=${pgPort} -c unix_socket_directories='$SOCKDIR'" -w start
          createdb -h "$SOCKDIR" -p ${pgPort} -U postgres app || true
          pg_ctl -D "$PGDATA" -m fast -w stop
          touch "$PGDATA/.app_created"
        fi

        exec postgres -D "$PGDATA"
      '';
    };

    migrate = pkgs.writeShellApplication {
      name = "pctl-pg-migrate";
      runtimeInputs = [pkgs.dbmate pkgs.postgresql];
      text = ''
        for _ in $(seq 1 50); do
          if pg_isready -h "$PCTL_HOST" -p ${pgPort} -U postgres -d app >/dev/null 2>&1; then
            break
          fi
          sleep 0.1
        done

        export DATABASE_URL="postgres://postgres@$PCTL_HOST:${pgPort}/app?sslmode=disable"
        dbmate --no-dump-schema -d "${migrationsDir}" up
      '';
    };

    web = pkgs.writeShellApplication {
      name = "pctl-pg-web";
      runtimeInputs = [rubyEnv];
      text = ''
        exec ruby ${./server.rb}
      '';
    };
  in {
    packages.${system}.pctl = pctl.lib.${system}.mkProject {
      services = {
        pg = {
          command = ["${pgRun}/bin/pctl-pg-run"];
          serviceConfig = {
            Type = "simple";
            StateDirectory = "pctl-@@PROJECT@@-pg";
            RuntimeDirectory = "pctl-@@PROJECT@@-pg";
            RuntimeDirectoryPreserve = "yes";
            Restart = "on-failure";
          };
        };

        migrate = {
          command = ["${migrate}/bin/pctl-pg-migrate"];
          dependsOn = ["pg"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = "yes";
          };
        };

        web = {
          command = ["${web}/bin/pctl-pg-web"];
          dependsOn = ["migrate"];
          env = {
            DB_CONN_MODE = "tcp";
            WEB_PORT = webPort;
            PG_PORT = pgPort;
            PG_DATABASE = "app";
            PG_USER = "postgres";
          };
          serviceConfig = {
            Restart = "on-failure";
          };
        };
      };
    };
  };
}
