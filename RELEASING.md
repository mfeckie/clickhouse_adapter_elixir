# Releasing

This repo is a monorepo of four separately-published Hex packages, each
depending on the one before it:

```
ch_codec  -->  ch_native  -->  ch_driver  -->  adapter
(NIF)          (block/col     (DBConnection   (Ecto.Adapters.ClickHouse,
               encoding)      driver)          Hex package name
                                                clickhouse_adapter_elixir)
```

Because a package published to Hex.pm cannot depend on another package via
a local `path:` reference -- every dependency must itself be resolvable
from Hex -- **publish order matters**. Each package's Hex-resolved version
constraint on its predecessor (`{:ch_codec, "~> 0.1"}` etc., see the
`*_dep/0` helpers in each `mix.exs`) is meaningless until that predecessor
actually exists on Hex at a matching version.

## Local development vs. publishing

Day to day, every project depends on its sibling via `path:` (e.g.
`ch_driver/mix.exs` depends on `{:ch_native, path: "../ch_native"}`) so you
can edit across package boundaries and immediately `mix test` without
publishing anything. This is the default with no configuration required.

When a project is built or published *as a Hex package* -- i.e. from
`mix hex.build`/`mix hex.publish`, whether run locally or in the
`*_release.yml` CI workflows -- set `HEX_PUBLISH=true` in the environment
first. Each affected `mix.exs` checks this and swaps its sibling `path:`
dep for the real Hex version constraint:

```console
$ cd ch_native
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

1. **ch_codec** -- tag `ch_codec-v<version>` (matches the existing
   convention already in use, see `.github/workflows/ch_codec_release.yml`).
   This triggers two things:
   - The NIF cross-compile matrix, which attaches a precompiled binary per
     target to a GitHub release for that tag (`build_release` job).
   - A `hex_publish` job (runs after the matrix, once release assets exist)
     that fetches those binaries with
     `mix rustler_precompiled.download ChCodec.Native --all --print` to
     produce `checksum-Elixir.ChCodec.Native.exs`, then runs
     `mix hex.publish --yes`.
   Both halves must succeed before moving on -- ch_native's build (via
   `RustlerPrecompiled`, transitively) doesn't need ch_codec's NIF to be
   precompiled, but installers of ch_native/ch_driver/adapter down the chain
   will need ch_codec's Hex package *and* its GitHub-release binaries to
   both be present.

2. **ch_native** -- tag `ch_native-v<version>`, once ch_codec's published
   version satisfies ch_native's `{:ch_codec, "~> 0.1"}` constraint (see
   `ch_native/mix.exs`). Triggers `.github/workflows/ch_native_release.yml`.

3. **ch_driver** -- tag `ch_driver-v<version>`, once ch_native is published
   and satisfies ch_driver's `{:ch_native, "~> 0.1"}` constraint. Triggers
   `.github/workflows/ch_driver_release.yml`.

4. **adapter** -- tag `adapter-v<version>`, once ch_driver is published and
   satisfies adapter's `{:ch_driver, "~> 0.1"}` constraint. Triggers
   `.github/workflows/adapter_release.yml`. Hex package name:
   `clickhouse_adapter_elixir` (the existing app name; see the naming note
   below).

If you bump a version constraint (e.g. moving ch_driver to require
`ch_native ~> 0.2` after a breaking change), update it in the dependent's
`mix.exs` *before* tagging that dependent's release.

## What CI does and doesn't do automatically

`ch_codec_ci.yml`, `ch_native_ci.yml`, `ch_driver_ci.yml`, and
`adapter_ci.yml` run on every push/PR touching their respective project (and
its upstream dependencies, since a change to e.g. ch_codec can affect
ch_native's build): compile with `--warnings-as-errors`, format check, and
`mix test`. `ch_driver_ci.yml` and `adapter_ci.yml` provision a live
ClickHouse instance via a `services:` block (same pinned image/ports as
`adapter/docker-compose.yml`); `adapter_ci.yml` additionally provisions
Kafka for `test/integration/kafka_ingestion_test.exs`.

The four `*_release.yml` workflows only run on their package's `<pkg>-v*`
tag (or manual `workflow_dispatch`) and require a real `HEX_API_KEY` repository
secret to actually publish -- pushing a tag without that secret configured
will fail at the `mix hex.publish` step rather than publish silently as
some anonymous/unauthenticated package.

## Package naming recommendation

Hex package names are kept identical to the existing app names by default:
`ch_codec`, `ch_native`, `ch_driver`, `clickhouse_adapter_elixir`. The first
three are fine as-is. `clickhouse_adapter_elixir` as a *public* Hex package
name is functional but not very discoverable or idiomatic for an Ecto
adapter -- most Ecto adapters on Hex are named `ecto_<db>` (e.g.
`ecto_sqlite3`, `myxql`, `ecto_mysql`). Consider `ecto_clickhouse` (or
similar) as the Hex package name at publish time if you want it to read
naturally alongside other Ecto adapters in search results -- this only
requires changing the `app:`/package name in `adapter/mix.exs` before its
first publish (renaming after publishing means yanking and re-publishing
under a new name, which Hex does not alias). Not renamed as part of this
change; flagging it here for a maintainer decision.
