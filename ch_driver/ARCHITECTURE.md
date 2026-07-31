# ch_driver internals

This is a map of how `ch_driver` is built, why a few non-obvious decisions
were made, and what we learned reverse-engineering ClickHouse's native TCP
protocol along the way. If you're using the library, you don't need any of
this — see the module docs and README instead. If you're changing the
driver, start here.

## Layering

```
ChDriver                    <- public API (start_link/query/query!/stream)
  ChDriver.DBConnection      <- DBConnection behaviour glue
    ChDriver.Connection      <- socket I/O, buffering, packet-loop dispatch
      ChDriver.Protocol      <- packet-type dispatch, handshake structs
        ChDriver.Protocol.Messages     <- per-message byte layouts
        ChDriver.Protocol.NativeBlock  <- Native block format, type dispatch
          ChDriver.Protocol.Block.Wrappers  <- Nullable/Array/Map/LowCardinality/Decimal
          ChDriver.Protocol.Block.Sparse    <- MergeTree sparse column format
        ChDriver.Protocol.Block.Compressed  <- LZ4 envelope framing
          ChDriver.Codec (+ Codec.Native)   <- Rust NIF: LZ4, CityHash
  ChDriver.Query             <- ?-placeholder lexing, DBConnection.Query impl
  ChDriver.Params            <- Elixir term -> ClickHouse literal + type
  ChDriver.Types / Types.Registry  <- column type-string parsing, scalar codecs
```

`ChDriver.Connection` owns socket I/O and buffering; `ChDriver.Protocol` (and
everything under it) is pure encode/decode with no I/O. That split is what
makes the protocol layer trivially testable without a live server.

## Handshake and the Addendum gotcha

The Hello exchange (ClientHello sent, ServerHello received) is always sent in
plaintext, never wrapped in a compressed envelope, even when compression is
negotiated for the rest of the connection.

The subtle part: ClickHouse requires a post-ServerHello "Addendum" — just a
raw length-prefixed string (the quota key, always empty here), with no
leading packet-type varint — whenever the client's advertised protocol
revision is at or above `DBMS_MIN_PROTOCOL_VERSION_WITH_ADDENDUM` (54458).
This driver's fixed revision (54465) always qualifies, so it always sends
the Addendum.

Skip this step and the connection silently desyncs: the server blocks
reading the Addendum string right after ServerHello, so the next bytes the
client sends (the start of a Query packet) get consumed as that string
instead. The failure mode that shows up is a bizarre, unrelated "Empty
query" error from the server, even though the Query packet itself was
correctly formed. This cost real debugging time before we found
`TCPHandler::receiveAddendum` in ClickHouse's `Server/TCPHandler.cpp`.

`ChDriver.Protocol.addendum_required?/0` and
`ChDriver.Protocol.Messages.encode_addendum/0` implement this.

## Protocol revision and ClientInfo

The driver advertises revision 54465 (`ChDriver.Protocol.Messages`). Several
optional ServerHello fields (timezone, display name, version patch) and the
ClientInfo sub-structure's fields are gated behind
`DBMS_MIN_REVISION_WITH_*` constants in ClickHouse's
`Core/ProtocolDefines.h`. 54465 is comfortably above all of them, so
`encode_client_info/0` always emits the full field set and
`decode_server_hello_body/1` always expects the full ServerHello shape —
there's no revision-negotiation branching needed in either direction, aside
from the addendum gate above.

One place this bit us: `ProfileInfo` (Server packet type 6) has a trailing
`applied_aggregation`/`rows_before_aggregation` pair in ClickHouse's own
source, but that pair is gated on `client_revision >=
DBMS_MIN_REVISION_WITH_ROWS_BEFORE_AGGREGATION` (54469) — evaluated against
the revision *we* advertised (54465), not the server's own revision. Since
54465 < 54469, the server never sends that trailing pair to us. Decoding it
anyway (which the constant alone would naively suggest) desyncs the stream
and corrupts every packet that follows. `decode_profile_info/1` deliberately
does not read those trailing fields.

## Query parameters: the escape-rounds discovery

ClickHouse query parameters piggyback on the same wire mechanism as
per-query settings: each parameter is a `(name, flags, value)` triple with a
"custom setting" flag bit set, terminated by an empty name. The `value` is
always sent as single-quoted, backslash-escaped text — the server re-parses
that text as a literal against the parameter's declared `{name:Type}`,
regardless of what the declared type actually is. Binding `{id:UInt64}` to
`5` sends the three bytes `'`, `5`, `'`, not a raw UInt64.

The part that took empirical digging: the server unescapes a scalar
parameter's value text **twice** before parsing it against the declared
type, but only **once** for each string inside an already-quoted
`Array(String)`/`Map` element. Escape a scalar value only once and it loses
backslashes asymmetrically — an odd leftover backslash fuses with the next
character into an unintended escape (`\b` becomes a backspace byte).
Escaping it twice round-trips correctly. But escape an `Array(String)`
value's elements twice and you corrupt them, because the array parser reads
each element with a single-escape "Quoted" reader — one level shallower than
the plain scalar path. `ReplaceQueryParameterVisitor` re-parses a scalar's
already-unescaped custom-setting value as escaped text a second time, and
does not do this for array elements.

This is undocumented ClickHouse behavior — there's no spec for it, just
observed round-trip failures until the escaping depth matched. It's why
`ChDriver.Params.escape_rounds/1` exists as its own function returning `1`
for lists and `2` for everything else, rather than a single fixed escaping
pass.

## Compression negotiation

Compression is opt-in (`:none` default, `:lz4` to enable) and is a
per-connection default overridable per query. The Query packet's
compression varint (0 = disabled, 1 = enabled) is not a "compress this one
field" toggle — per `TCPHandler::receiveQuery`/`TCPHandler::run` in
ClickHouse's own source, setting it to 1 tells the server that **both**
directions of that query's block traffic are compressed from that point on.
The server wraps every Data/ProfileEvents block it sends in a compressed
envelope (`ChDriver.Protocol.Block.Compressed`), and it expects the client's
own Data packets — including the empty external-table block every query
sends — to arrive wrapped the same way. Send a plain block after declaring
compression enabled and the server blocks forever waiting for a compression
envelope header that never arrives.

We reverse-engineered this by running a live ClickHouse 24.8 server and
watching what broke.

**ProfileEvents is the one exception**, discovered the hard way: verified
live against ClickHouse 24.8 with compression negotiated on, the server
sends ProfileEvents blocks in plain, un-enveloped Native format regardless
of the negotiated compression setting. Unlike Data, ProfileEvents is written
via its own dedicated `NativeWriter` straight to the raw output stream,
bypassing the query's `maybe_compressed_out`. This driver's first cut at
compression forced `:lz4` decoding onto ProfileEvents too, which desynced
the stream right after the first ProfileEvents packet — the decoder sat
waiting forever for a compression envelope header that was never written.
`ChDriver.Protocol.decode_packet/2` now always decodes ProfileEvents as
`:none`, independent of the negotiated `compression` setting. Every other
non-block packet type (Progress, ProfileInfo, Exception, EndOfStream, Pong)
was already plain regardless of compression.

## Streaming and the cursor state problem

ClickHouse's native protocol is unpipelined request/response — one query in
flight per socket at a time — but it does deliver a query's result as a
header block, then N Data blocks, then EndOfStream. That's real incremental
structure, and `ChDriver.Connection.start_stream/3` /
`stream_fetch/2` / `cancel_stream/2` expose it block-at-a-time instead of
always accumulating everything into memory the way `query/3` does.

The tricky part is fitting that into `DBConnection`'s cursor callbacks
(`handle_declare/4`, `handle_fetch/4`, `handle_deallocate/4`). DBConnection
does **not** thread an updated cursor value between fetches — its
`handle_fetch/4` callback returns `new_state`, not a new cursor — so the
cursor `handle_declare/4` hands back is a bare `reference/0` that's never
actually inspected. The real mutable stream position (unconsumed buffer
tail, known columns, whether EndOfStream has been seen) has to live in the
connection's own `state`, under `state.stream`, since `state` — unlike the
cursor — is threaded through every callback normally.

This only works because `DBConnection.stream/4`'s own `resource/5` helper
requires an already-checked-out `%DBConnection{}` for the whole
declare/fetch*/deallocate sequence (see `ChDriver.stream/2,3,4`), so there's
no risk of a pooled connection handing the cursor's socket to a different
physical connection mid-stream.

`ChDriver.Connection.start_stream/3` also has to skip ClickHouse's
structure-only "header" block (0 rows, real columns) before returning — a
subtlety worth remembering if you ever touch `receive_first_nonempty_block/6`:
a genuinely empty result and a header-only response look identical at that
point, and a tiny result can in principle arrive combined with the header in
a single block, which is why the header's own (almost-always-empty) rows are
stashed as `pending` rather than discarded.

Cancelling a stream early (`cancel_stream/2`) sends ClickHouse's Cancel
packet (Client packet type 3) and then keeps draining blocks off the socket
until EndOfStream, since blocks already in flight before the server notices
the cancellation can still arrive. There's no server-side cursor to close
the way Postgres has one — draining is the only way to leave the connection
byte-position-correct for the next query.

## Query struct: why parameter types aren't resolved at parse time

`ChDriver.Query`'s `?`-placeholder lexing (`lex_placeholders/1`) is a
one-time, quote-aware scan cached by DBConnection's own query cache across
repeated executions of the same prepared statement. But ClickHouse's native
protocol has no untyped placeholder syntax — every bound parameter needs a
concrete `{name:Type}` type, and `nil` can't be bound as a typed parameter
at all (see `ChDriver.Params` below). Both the concrete type and the
nil-ness of a value are properties of a specific call's arguments, and
`DBConnection.Query.parse/2` runs before any params exist.

Two executions of the same cached query can legitimately bind different
shapes at the same position — `Repo.insert!/1` on a schema with a nullable
column, called once with a value and once with `nil`, reuses the identical
cached insert statement both times. So `parse/2` only resolves *where* the
placeholders are (expensive, quote-aware, cached); `encode/3` resolves *what*
to bind this call's actual values as (cheap, per-execution); and
`ChDriver.DBConnection.handle_execute/4` splices the two together via
`to_wire/2` into the final wire statement and params for that one call.

`describe/2` is an intentional no-op — ClickHouse's native protocol has no
server-side Describe round-trip the way Postgres's Parse/Describe/Bind flow
has one, so there's nothing to send.

## Params: why there's no `nil` clause

`ChDriver.Params.type/1` and `text/1` have no clause for `nil` on purpose.
There's no ClickHouse parameter type that parses NULL correctly against
every column type it might be compared against — binding a
`Nullable(String)` NULL parameter against an `Int32` column fails with
"Attempt to read after eof... while converting '' to Int32". So `nil`
callers are expected to inline a literal `NULL` token into the query text
themselves, which is exactly what `ChDriver.Query.to_wire/2` does for a
`{name, :null}` encoded param.

`DateTime.to_string/1` appends a "Z"/offset suffix that ClickHouse's
DateTime literal parser rejects outright, which is why `text/1` only
accepts UTC `DateTime` values (offset-less ClickHouse `DateTime` has no
concept of a UTC offset to compare against) and raises for anything else.

## Native block decoding

`ChDriver.Protocol.NativeBlock` owns block/packet framing and top-level type
dispatch. The type system is split by concern, and this is the map for
adding a new type:

- `ChDriver.Types` — parses a column type *string* (e.g.
  `"Nullable(String)"`) into its parts. Add a new `parse_*/1` clause for a
  new wrapper syntax.
- `ChDriver.Types.Registry` — the scalar/fixed-width codec table
  (`column_codec/1`) and primitive wire readers. Add a new scalar type here.
- `ChDriver.Protocol.Block.Wrappers` — decoders for `Nullable(T)`,
  `Array(T)`, `Map(K, V)`, `LowCardinality(T)`, `Decimal(P, S)`. Add a new
  wrapper/compound decoder here, plus a dispatch clause in
  `NativeBlock.decode_column_data/3` and a parser in `ChDriver.Types`.
- `ChDriver.Protocol.Block.Sparse` — MergeTree's sparse column
  serialization.

`decode_column_data/3` classifies a type string once into a tagged tuple
(`{:nullable, inner}`, `{:array, inner}`, etc., or `{:plain, type}` if no
wrapper parser matches) and dispatches on that tuple with one flat `case`
clause per kind. `Wrappers` and `Sparse` call back into
`NativeBlock.decode_column_data/3` for their inner type(s) — that mutual
recursion across the module boundary is what makes arbitrarily nested types
like `Array(Nullable(String))` or `Map(String, Array(UInt32))` work without
any special-casing for depth.

Only a pragmatic subset of ClickHouse's type system is supported — enough
for the query shapes this driver and the Ecto adapter built on top of it
actually need, plus the handful of scalar types ClickHouse's own
ProfileEvents packets carry alongside every query result.

### Wire formats worth remembering

- **`Nullable(T)`**: a `num_rows`-byte null map (1 = null), immediately
  followed by `T`'s own column data for *all* rows, including null ones
  (whose value is a meaningless placeholder we discard rather than decode).
- **`Array(T)`**: `num_rows` cumulative little-endian `UInt64` offsets
  (`offsets[i]` is the exclusive end index of row i's elements in the
  flattened array), followed by the flattened element values for all rows,
  decoded recursively via `T`.
- **`Map(K, V)`**: ClickHouse implements `Map(K, V)` internally as
  `Array(Tuple(K, V))`, and the wire format follows that exactly — but not
  by interleaving `(key, value)` pairs. It's `Array`-style offsets, then the
  *entire* flattened key column, then the *entire* flattened value column
  (each field of the `Tuple` gets its own back-to-back sub-stream). Reading
  it as "all offsets, then all keys, then all values" round-trips
  `{'a':1,'b':2}` correctly; an interleaved-pairs reading misaligns a
  `String` length-prefix against unrelated numeric bytes. `Tuple(...)` on
  its own isn't supported as a directly-selectable column type — only as
  `Map`'s implicit representation — since generalizing it to arbitrary arity
  isn't needed for anything this driver currently does.
- **`LowCardinality(T)`**: dictionary-encoded. `key_version` (always 1),
  `index_type_and_flags` (low byte picks the per-row index width: 0=UInt8,
  1=UInt16, 2=UInt32, 3=UInt64; remaining bits are flags always set for the
  single-block dictionaries this driver ever sees), `dictionary_size`,
  that many entries of `T`'s own encoding (dictionary entry 0 is always the
  implicit default value), `index_count`, then that many little-endian
  indices into the dictionary. A zero-row block writes none of these
  fields at all — parsing them unconditionally on an empty "header" block
  hangs the connection waiting for bytes that were never sent.
- **`Decimal(P, S)`**: a fixed-width signed little-endian integer holding
  the unscaled value. Byte width is chosen from precision `P` alone (never
  stored on the wire) via ClickHouse's own precision tiers: ≤9 → 4 bytes,
  ≤18 → 8 bytes, ≤38 → 16 bytes, else 32 bytes. `Decimal32/64/128/256(S)`
  are just fixed-precision aliases (9/18/38/76) for this same encoding.
- **`UUID`**: 16 bytes laid out as the UUID's standard text-representation
  bytes with *each 8-byte half independently byte-reversed* — not naive
  byte order, and not a swap of the two halves either. For UUID
  `61f0c404-5cb3-11e7-907b-a6006ad3dba0`, ClickHouse's wire bytes are
  `e7 11 b3 5c 04 c4 f0 61 a0 db d3 6a 00 a6 7b 90` — reversing bytes 0-7 and
  separately bytes 8-15 recovers the standard form.
- **`IPv4`**: same little-endian `UInt32` encoding as any other integer
  type. `192.168.1.1` is `0xC0A80101` read big-endian; the wire bytes
  `01 01 A8 C0` are that value's little-endian byte order. Decoded by
  re-reading as big-endian and splitting into octets.
- **`IPv6`**: a plain 16-byte value in standard network byte order — no
  reversal at all, unlike `UUID`. Decoded via `:inet.ntoa/1` on the 8
  big-endian 16-bit groups.
- **`FixedString(N)`**: exactly `N` raw bytes per row, right-padded with
  `0x00` — no length prefix at all, unlike `String`. ClickHouse does not
  trim the padding back out on `SELECT`; the padding is part of the actual
  value, so it round-trips verbatim, trailing NULs included.
- **`DateTime`**: little-endian `UInt32` Unix-epoch seconds, no fractional
  component (that's `DateTime64(N)`, not implemented). Decoded to a UTC
  `DateTime.t()` — the epoch itself is timezone-agnostic; UTC is just the
  zone used to represent it as an Elixir struct, matching how Ecto's
  built-in `:naive_datetime`/`:utc_datetime` types expect to load a UTC
  `DateTime`.

### Sparse serialization

ClickHouse automatically switches a MergeTree column to "sparse"
serialization once enough of its values equal the type's default
(`ratio_of_defaults_for_sparse_serialization`, default 0.9) — regardless of
whether anyone asked for it. On the wire, this shows up as the
`has_custom_serialization` byte being 1, followed by a "serialization kind"
byte (0 = DEFAULT, never actually sent since `hasCustomSerialization()` is
false whenever kind is DEFAULT; 1 = SPARSE, the only other kind that exists
as of ClickHouse 24.8).

Sparse's own encoding is two back-to-back sub-streams, not a
`Nullable`-style parallel null map:

- **`SparseOffsets`**: a sequence of `UInt64` varints, each a "group size" —
  the count of consecutive default-valued rows since the last non-default
  row — immediately followed by one non-default row's position. The final
  varint has bit 62 set (`END_OF_GRANULE_FLAG = 1 <<< 62`, safe because
  ClickHouse varints only ever carry values below 2^63) and its low bits
  are the count of trailing default rows with no following value. For 10
  rows with non-default values at (0-indexed) positions 2 and 5, the stream
  is the three varints `2`, `2`, `4 | END_OF_GRANULE_FLAG`. There's always
  at least one flagged varint, even for an all-default or zero-row block.
- **`SparseElements`**: exactly as many densely-packed values of the inner
  type as there were non-default rows, decoded recursively.

Decoding walks the offsets and interleaves the decoded non-default values at
their positions with the inner type's default value everywhere else. Only
types `default_value/1` knows a default for are supported — anything else
is a clear `{:error, {:unsupported_sparse_default, type}}` rather than a
guess.

## Buffer size guard

Every receive loop (`receive_server_hello/4`, `receive_query_result/6`,
`receive_stream_block/6`, `receive_pong/4`) accumulates bytes from
`:gen_tcp.recv/3` into a growing buffer until a decoder returns something
other than `:incomplete`. A garbled length-prefix varint — a corrupted
column's declared string length, or a block's declared row/column count,
whether from a malicious server or a client-side protocol desync — can make
a decoder wait forever for byte counts that are never coming, growing that
buffer without bound until `recv_timeout` finally fires, by which point the
process may already be holding an enormous binary.

`@default_max_buffer_size` (64MB) guards against this, checked *before*
issuing another `recv` call so a single oversized/garbled response already
sitting in the socket buffer fails immediately without waiting on the
network. This mirrors Postgrex's own `@max_packet` default and rationale
(see `postgrex/lib/postgrex/protocol.ex`).

## Error vs. disconnect semantics

`ChDriver.DBConnection` treats socket-level failures (`:gen_tcp` errors like
`:closed`/`:timeout`) as `:disconnect`, tearing the pool connection down and
reconnecting — the socket itself is no longer trustworthy. A decoded
`%ChDriver.Error{}` from a well-formed Exception packet is returned as an
ordinary `:error` instead, since by the time that packet arrives the
response stream has already been fully consumed and the socket is still in
a valid, reusable state for the next query. Same logic applies during
`handle_deallocate/4`'s drain: an Exception packet arriving mid-drain still
leaves the socket byte-position-correct, so the connection stays in the
pool.

There's no transaction support in ClickHouse's native protocol as used
here, so `handle_begin/2`/`handle_commit/2`/`handle_rollback/2` are
unimplemented stubs that return an explicit error rather than silently
pretending to do something.

## Why `ChDriver.Query` implements `String.Chars`

`Ecto.Adapters.SQL.log/5` calls `to_string/1` on the cached query struct
when emitting `[:ecto_adapter, :query]` telemetry. Without a `String.Chars`
implementation, every successful query raised a harmless-but-noisy
`Protocol.UndefinedError` from inside the logging callback, after the query
itself had already succeeded. `to_string/1` just returns the original SQL
text.
