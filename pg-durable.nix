# pg-durable.nix
# Package definition for the pg_durable PostgreSQL extension.
#
# The purpose of this file is to build Microsoft's pg_durable (durable SQL
# functions) as a native NixOS PostgreSQL extension so it can be plugged into
# the iDempiere cluster's `services.postgresql` (see idempiere-prerequisites.nix).
#
# pg_durable is a pgrx (Rust) extension. Nixpkgs already ships the exact
# toolchain it pins (cargo-pgrx 0.16.1, per its Cargo.toml) and a generic
# `buildPgrxExtension` builder, so this file just wires those together.
#
# This is intentionally one self-contained file: the build recipe below is
# iDempiere-agnostic and can be lifted into a dedicated `pg-durable` repo
# unchanged if a second consumer ever needs it.
{
  lib,
  buildPgrxExtension,
  cargo-pgrx_0_16_1,
  fetchurl,
  pkg-config,
  openssl,
  postgresql,
}:

buildPgrxExtension (finalAttrs: {
  pname = "pg_durable";
  version = "0.2.3";

  # Pin the published release source archive (verified against the release's
  # SHA256SUMS). This is still a source build (compiles the pgrx/Rust tree);
  # the released .deb would avoid compiling but is Debian-linked.
  src = fetchurl {
    url = "https://github.com/microsoft/pg_durable/releases/download/v${finalAttrs.version}/pg_durable-${finalAttrs.version}.tar.gz";
    hash = "sha256-D6IT2tYuHZUP12sD1lnyATIt7kqiAYl3cp9IHFyxUQI=";
  };

  # Vendored-dependency hash. Resolved on first build (set to lib.fakeHash and
  # copy the hash Nix reports).
  cargoHash = "sha256-3E/ItduC7iFmpfZ6J1uXrn9wW/5zYOpeEspE4pty88k=";

  # Must match the pin in pg_durable's Cargo.toml (=0.16.1).
  cargo-pgrx = cargo-pgrx_0_16_1;
  inherit postgresql;

  nativeBuildInputs = [ pkg-config ];
  # pg_durable deliberately uses native-tls (openssl), not rustls.
  buildInputs = [ openssl ];

  # Select the PG major feature explicitly. cargo-pgrx package builds with
  # exactly the features we pass here.
  buildFeatures = [ "pg${lib.versions.major postgresql.version}" ];

  # The pgrx test harness needs a live server and the pg_test feature; skip it
  # during the Nix build. We only want the built artifact here.
  doCheck = false;

  meta = {
    description = "Durable SQL functions for PostgreSQL (pgrx extension)";
    homepage = "https://github.com/microsoft/pg_durable";
    license = lib.licenses.postgresql;
    platforms = lib.platforms.linux;
  };
})
