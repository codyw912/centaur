{ pkgs, ... }:

{
  packages = [
    pkgs.bun
    pkgs.docker-client
    pkgs.git
    pkgs.jujutsu
    pkgs.kubernetes-helm
    pkgs.kubectl
    pkgs.just
    pkgs.jq
    pkgs.nodejs_22
    pkgs.openssl
    pkgs.postgresql_16
    pkgs.uv
  ];

  languages.python = {
    enable = true;
    package = pkgs.python311;
  };

  scripts.api-test.exec = ''
    if [ -d services/api ]; then
      cd services/api
    fi
    PATH="${pkgs.docker-client}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:${pkgs.gawk}/bin:${pkgs.gnutar}/bin:${pkgs.gzip}/bin:${pkgs.openssl}/bin:${pkgs.uv}/bin:${pkgs.bash}/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      ${pkgs.uv}/bin/uv run --python 3.11 pytest "$@"
  '';

  scripts.api-test-local-pg.exec = ''
    if [ -d services/api ]; then
      cd services/api
    fi
    ${pkgs.uv}/bin/uv run --python 3.11 pytest "$@"
  '';

  enterShell = ''
    export UV_PYTHON=3.11
    echo "Centaur dev shell: use 'api-test' for API tests with Docker/ParadeDB fallback."
    echo "Use 'api-test-local-pg' only when local Postgres has required extensions."
  '';
}
