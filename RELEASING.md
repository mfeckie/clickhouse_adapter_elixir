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

Publishing ch_driver locally is one step longer, since it also needs its
NIF checksum file generated first (see the `FORCE_COMPILE` note under
*Publish sequence* below for why):

```console
$ cd ch_driver
$ FORCE_COMPILE=1 mix compile
$ mix rustler_precompiled.download ChDriver.Codec.Native --all --print
$ mix hex.build     # or mix hex.publish --yes
```

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

   **The checksum step needs `FORCE_COMPILE=1`.** RustlerPrecompiled
   refuses to trust any NIF -- downloaded or locally built -- until that
   checksum file already exists, and a fresh checkout has none (it's
   gitignored on purpose, generated at build/publish time, not committed).
   Running the download task itself triggers an implicit `mix compile`,
   which hits that same check before the download logic ever runs.
   `FORCE_COMPILE=1` makes that implicit compile fall back to building the
   NIF locally instead of downloading it, which sidesteps the check for
   long enough to let `--all` then fetch and checksum every other target
   from the GitHub release. This is already wired into the `hex_publish`
   job's env -- if you're doing this by hand locally, run it in two steps:

       cd ch_driver
       FORCE_COMPILE=1 mix compile
       mix rustler_precompiled.download ChDriver.Codec.Native --all --print

   (The single-command form, `FORCE_COMPILE=1 mix rustler_precompiled.download ...`,
   also works -- the env var covers the implicit compile either way. Two
   steps just makes it obvious what's happening if something goes wrong.)

   **Publishing to Hex.pm needs 2FA if you're doing it from your own
   authenticated session** (`mix hex.user auth`), the same as publishing
   any other package. CI sidesteps this entirely: `hex.publish` run with
   `HEX_API_KEY` set in the environment authenticates via the key instead
   of your user session, and API-key auth doesn't prompt for 2FA. So a real
   tag push, with the secret configured, publishes non-interactively end to
   end. If you publish locally instead (e.g. to unblock a release while
   iterating on the workflow itself), expect the 2FA prompt and have your
   authenticator ready.

2. **clickhouse_adapter_ecto** -- tag `adapter-v<version>` (short tag prefix
   kept deliberately -- see the naming note at the top of
   `.github/workflows/clickhouse_adapter_ecto_release.yml`), once ch_driver
   is published and satisfies clickhouse_adapter_ecto's
   `{:ch_driver, "~> 0.1"}` constraint. Triggers
   `.github/workflows/clickhouse_adapter_ecto_release.yml`. Hex package name:
   `clickhouse_adapter_ecto` (decided -- see the naming note below).

   This one doesn't need the `FORCE_COMPILE`/checksum dance: with
   `HEX_PUBLISH=true`, `mix deps.get` fetches ch_driver as a real Hex
   package, and Hex packages ship their checksum file bundled in the
   tarball already (it's in ch_driver's own `package.files`). Nothing to
   generate.

If you bump a version constraint (e.g. moving clickhouse_adapter_ecto to
require `ch_driver ~> 0.2` after a breaking change), update it in
`clickhouse_adapter_ecto/mix.exs` *before* tagging its release.

## Hex docs are pinned per version

Once a version is published, its docs on hexdocs.pm are frozen -- editing
`@moduledoc`/`@doc` content and pushing to `main` does nothing to what's
already live. There's no way to patch published docs in place; the only
fix is to cut a new version. Keep this in mind before spending real time
polishing documentation on a version you don't intend to re-release --
land the doc fixes, then bump and tag when you're ready for them to
actually show up.

## What CI does and doesn't do automatically

`ch_driver_ci.yml` and `clickhouse_adapter_ecto_ci.yml` run on every push/PR
touching their respective project (and, for `clickhouse_adapter_ecto_ci.yml`,
its upstream `ch_driver` dependency too, since a change there can affect
clickhouse_adapter_ecto's build): fetch deps, generate ch_driver's NIF
checksum file (see the `FORCE_COMPILE` note under *Publish sequence* --
this needs doing even for a plain test run, not just a release, since it's
what lets `mix compile` trust the NIF at all on a checkout that's never
built it before), compile with `--warnings-as-errors`, format check, and
`mix test`. Both provision a live ClickHouse instance via a `services:`
block (same pinned image/ports as `clickhouse_adapter_ecto/docker-compose.yml`);
`clickhouse_adapter_ecto_ci.yml` additionally provisions Kafka for
`test/integration/kafka_ingestion_test.exs`. `ch_driver_ci.yml` also
installs a Rust toolchain and runs `cargo test` against
`ch_driver/native/ch_driver_native` directly, since ch_driver now owns the
Rust NIF build.

The two `*_release.yml` workflows only run on their package's tag prefix
(or manual `workflow_dispatch`) and require a real `HEX_API_KEY` repository
secret to actually publish -- pushing a tag without that secret configured
will fail at the `mix hex.publish` step rather than publish silently as
some anonymous/unauthenticated package. `HEX_API_KEY` is configured on this
repo as of the 0.1.0 releases; `clickhouse_adapter_ecto`'s went out through
this exact CI path with no manual steps. ch_driver's didn't -- see the note
under *Publish sequence* above about its checksum-step fix landing after
0.1.0 was already published by hand, which means that job's automated path
is still unproven by a real tag push.

## Package naming

Both Hex package names match their app names: `ch_driver`,
`clickhouse_adapter_ecto`. `clickhouse_adapter_ecto` isn't the most
discoverable name for an Ecto adapter -- most on Hex follow `ecto_<db>`
(`ecto_sqlite3`, `myxql`, `ecto_mysql`) -- but that ship has sailed: it's
already published under this name, and Hex has no rename, only yank +
republish under a different name (which breaks every existing installer's
lock file). Decided to keep it as-is rather than take on that churn.
