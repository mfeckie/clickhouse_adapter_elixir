# Releasing

This repo is a monorepo of two separately-published Hex packages, each
depending on the one before it:

```
ch_driver  -->  adapter
(DBConnection    (Ecto.Adapters.ClickHouse,
 driver,          Hex package name
 including its    clickhouse_adapter_elixir)
 LZ4/CityHash
 compression NIF
 and compressed-
 block wire
 envelope)
```

Because a package published to Hex.pm cannot depend on another package via
a local `path:` reference -- every dependency must itself be resolvable
from Hex -- **publish order matters**. adapter's Hex-resolved version
constraint on ch_driver (`{:ch_driver, "~> 0.1"}`, see the `ch_driver_dep/0`
helper in `adapter/mix.exs`) is meaningless until ch_driver actually exists
on Hex at a matching version.

## Local development vs. publishing

Day to day, `adapter` depends on `ch_driver` via `path:` (`adapter/mix.exs`
depends on `{:ch_driver, path: "../ch_driver"}`) so you can edit across the
package boundary and immediately `mix test` without publishing anything.
This is the default with no configuration required.

When a project is built or published *as a Hex package* -- i.e. from
`mix hex.build`/`mix hex.publish`, whether run locally or in the
`*_release.yml` CI workflows -- set `HEX_PUBLISH=true` in the environment
first. `adapter/mix.exs` checks this and swaps its `ch_driver` `path:` dep
for the real Hex version constraint:

```console
$ cd adapter
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

2. **adapter** -- tag `adapter-v<version>`, once ch_driver is published and
   satisfies adapter's `{:ch_driver, "~> 0.1"}` constraint. Triggers
   `.github/workflows/adapter_release.yml`. Hex package name:
   `clickhouse_adapter_elixir` (the existing app name; see the naming note
   below).

If you bump a version constraint (e.g. moving adapter to require
`ch_driver ~> 0.2` after a breaking change), update it in `adapter/mix.exs`
*before* tagging adapter's release.

## What CI does and doesn't do automatically

`ch_driver_ci.yml` and `adapter_ci.yml` run on every push/PR touching their
respective project (and, for `adapter_ci.yml`, its upstream `ch_driver`
dependency too, since a change there can affect adapter's build): compile
with `--warnings-as-errors`, format check, and `mix test`. Both provision a
live ClickHouse instance via a `services:` block (same pinned image/ports as
`adapter/docker-compose.yml`); `adapter_ci.yml` additionally provisions
Kafka for `test/integration/kafka_ingestion_test.exs`. `ch_driver_ci.yml`
also installs a Rust toolchain and runs `cargo test` against
`ch_driver/native/ch_driver_native` directly, since ch_driver now owns the
Rust NIF build.

The two `*_release.yml` workflows only run on their package's `<pkg>-v*` tag
(or manual `workflow_dispatch`) and require a real `HEX_API_KEY` repository
secret to actually publish -- pushing a tag without that secret configured
will fail at the `mix hex.publish` step rather than publish silently as
some anonymous/unauthenticated package.

## Package naming recommendation

Hex package names are kept identical to the existing app names by default:
`ch_driver`, `clickhouse_adapter_elixir`. `ch_driver` is fine as-is.
`clickhouse_adapter_elixir` as a *public* Hex package name is functional but
not very discoverable or idiomatic for an Ecto adapter -- most Ecto adapters
on Hex are named `ecto_<db>` (e.g. `ecto_sqlite3`, `myxql`, `ecto_mysql`).
Consider `ecto_clickhouse` (or similar) as the Hex package name at publish
time if you want it to read naturally alongside other Ecto adapters in
search results -- this only requires changing the `app:`/package name in
`adapter/mix.exs` before its first publish (renaming after publishing means
yanking and re-publishing under a new name, which Hex does not alias). Not
renamed as part of this change; flagging it here for a maintainer decision.
