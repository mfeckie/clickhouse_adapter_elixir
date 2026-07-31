# Releasing

This repo is a monorepo of two separately-published Hex packages, each
depending on the one before it:

```
ch_driver  -->  clickhouse_adapter_ecto
(DBConnection    (Ecto.Adapters.ClickHouse,
 driver,          Hex package name
 including its    clickhouse_adapter_ecto)
 LZ4/CityHash
 compression NIF
 and compressed-
 block wire
 envelope)
```

Because a package published to Hex.pm cannot depend on another package via
a local `path:` reference -- every dependency must itself be resolvable
from Hex -- **publish order matters**. clickhouse_adapter_ecto's Hex-resolved
version constraint on ch_driver (`{:ch_driver, "~> 0.1"}`, see the
`ch_driver_dep/0` helper in `clickhouse_adapter_ecto/mix.exs`) is meaningless
until ch_driver actually exists on Hex at a matching version.

## Local development vs. publishing

Day to day, `clickhouse_adapter_ecto` depends on `ch_driver` via `path:`
(`clickhouse_adapter_ecto/mix.exs` depends on
`{:ch_driver, path: "../ch_driver"}`) so you can edit across the package
boundary and immediately `mix test` without publishing anything. This is
the default with no configuration required.

When a project is built or published *as a Hex package* -- i.e. from
`mix hex.build`/`mix hex.publish`, whether run locally or in the
`*_release.yml` CI workflows -- set `HEX_PUBLISH=true` in the environment
first. `clickhouse_adapter_ecto/mix.exs` checks this and swaps its
`ch_driver` `path:` dep for the real Hex version constraint:

```console
$ cd clickhouse_adapter_ecto
$ HEX_PUBLISH=true mix deps.get
$ HEX_PUBLISH=true mix hex.build     # or mix hex.publish
```

Without `HEX_PUBLISH=true`, `mix hex.build`/`mix hex.publish` will refuse to
proceed (Hex rejects `path:` deps in a package), which is the intended
guardrail against accidentally publishing a package that still points at a
local sibling.

## Publish sequence

Publish strictly in this order -- each step's tag-gated release workflow
runs `mix hex.publish --yes` non-interactively once triggered:

1. **ch_driver** -- tag `ch_driver-v<version>` (matches the existing
   convention already in use, see `.github/workflows/ch_driver_release.yml`).
   This triggers two things:
   - The NIF cross-compile matrix, which attaches a precompiled binary per
     target to a GitHub release for that tag (`build_release` job) --
     `ChDriver.Codec.Native`'s Rust crate (`native/ch_driver_native`).
   - A `hex_publish` job (runs after the matrix, once release assets exist)
     that fetches those binaries with
     `mix rustler_precompiled.download ChDriver.Codec.Native --all --print`
     to produce `checksum-Elixir.ChDriver.Codec.Native.exs`, then runs
     `mix hex.publish --yes`.
   Both halves must succeed before moving on -- installers of adapter down
   the chain will need ch_driver's Hex package *and* its GitHub-release NIF
   binaries to both be present.

2. **clickhouse_adapter_ecto** -- tag `adapter-v<version>` (short tag prefix
   kept deliberately -- see the naming note at the top of
   `.github/workflows/clickhouse_adapter_ecto_release.yml`), once ch_driver
   is published and satisfies clickhouse_adapter_ecto's
   `{:ch_driver, "~> 0.1"}` constraint. Triggers
   `.github/workflows/clickhouse_adapter_ecto_release.yml`. Hex package name:
   `clickhouse_adapter_ecto` (the app name; see the naming note below).

If you bump a version constraint (e.g. moving clickhouse_adapter_ecto to
require `ch_driver ~> 0.2` after a breaking change), update it in
`clickhouse_adapter_ecto/mix.exs` *before* tagging its release.

## What CI does and doesn't do automatically

`ch_driver_ci.yml` and `clickhouse_adapter_ecto_ci.yml` run on every push/PR
touching their respective project (and, for `clickhouse_adapter_ecto_ci.yml`,
its upstream `ch_driver` dependency too, since a change there can affect
clickhouse_adapter_ecto's build): compile with `--warnings-as-errors`,
format check, and `mix test`. Both provision a live ClickHouse instance via
a `services:` block (same pinned image/ports as
`clickhouse_adapter_ecto/docker-compose.yml`); `clickhouse_adapter_ecto_ci.yml`
additionally provisions Kafka for
`test/integration/kafka_ingestion_test.exs`. `ch_driver_ci.yml` also
installs a Rust toolchain and runs `cargo test` against
`ch_driver/native/ch_driver_native` directly, since ch_driver now owns the
Rust NIF build.

The two `*_release.yml` workflows only run on their package's tag prefix
(or manual `workflow_dispatch`) and require a real `HEX_API_KEY` repository
secret to actually publish -- pushing a tag without that secret configured
will fail at the `mix hex.publish` step rather than publish silently as
some anonymous/unauthenticated package.

## Package naming recommendation

Hex package names are kept identical to the existing app names by default:
`ch_driver`, `clickhouse_adapter_ecto`. `ch_driver` is fine as-is.
`clickhouse_adapter_ecto` as a *public* Hex package name is functional but
not very discoverable or idiomatic for an Ecto adapter -- most Ecto adapters
on Hex are named `ecto_<db>` (e.g. `ecto_sqlite3`, `myxql`, `ecto_mysql`).
Consider `ecto_clickhouse` (or similar) as the Hex package name at publish
time if you want it to read naturally alongside other Ecto adapters in
search results -- this only requires changing the `app:`/package name in
`clickhouse_adapter_ecto/mix.exs` before its first publish (renaming after
publishing means yanking and re-publishing under a new name, which Hex does
not alias). Not renamed as part of this change; flagging it here for a
maintainer decision.
