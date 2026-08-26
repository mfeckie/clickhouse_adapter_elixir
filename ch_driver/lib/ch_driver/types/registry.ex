defmodule ChDriver.Types.Registry do
  @moduledoc """
  The scalar/fixed-width column type codec table, plus the primitive wire
  readers it's built on.

  Covers ClickHouse's fixed-width integer and float types, `String`,
  `Bool`, `DateTime`, `Enum8`/`Enum16`, `UUID`, `IPv4`, and `IPv6`. Adding
  a new scalar type is a one-line addition to `column_codec/1`.

  `UUID` values decode to their standard hyphenated text form. `IPv4`/`IPv6`
  decode to dotted-quad / colon-hex text. `DateTime` decodes to a UTC
  `DateTime.t()`. `Date` decodes to a `Date.t()`. `Bool` decodes to a
  boolean.

  `DateTime64(P)` is parameterized by its precision, so it can't be a
  fixed entry in `column_codec/1`'s table -- it's dispatched from
  `ChDriver.Protocol.NativeBlock` through `decode_datetime64/2` instead.
  """

  alias ChDriver.Protocol.Varint

  @doc """
  Looks up the fixed-width/string codec for a scalar ClickHouse type name.
  Returns `{:fixed, byte_size, unpack_fun}`, `:string`, or `:unsupported`.
  """
  def column_codec("UInt8"), do: {:fixed, 1, fn <<v::unsigned-little-8>> -> v end}
  def column_codec("UInt16"), do: {:fixed, 2, fn <<v::unsigned-little-16>> -> v end}
  def column_codec("UInt32"), do: {:fixed, 4, fn <<v::unsigned-little-32>> -> v end}
  def column_codec("UInt64"), do: {:fixed, 8, fn <<v::unsigned-little-64>> -> v end}
  def column_codec("Int8"), do: {:fixed, 1, fn <<v::signed-little-8>> -> v end}
  def column_codec("Int16"), do: {:fixed, 2, fn <<v::signed-little-16>> -> v end}
  def column_codec("Int32"), do: {:fixed, 4, fn <<v::signed-little-32>> -> v end}
  def column_codec("Int64"), do: {:fixed, 8, fn <<v::signed-little-64>> -> v end}
  def column_codec("Float32"), do: {:fixed, 4, fn <<v::float-little-32>> -> v end}
  def column_codec("Float64"), do: {:fixed, 8, fn <<v::float-little-64>> -> v end}
  def column_codec("DateTime"), do: {:fixed, 4, &decode_datetime/1}
  def column_codec("Date"), do: {:fixed, 2, &decode_date/1}
  def column_codec("String"), do: :string
  def column_codec("Bool"), do: {:fixed, 1, &decode_bool/1}
  def column_codec("UUID"), do: {:fixed, 16, &decode_uuid/1}
  def column_codec("IPv4"), do: {:fixed, 4, &decode_ipv4/1}
  def column_codec("IPv6"), do: {:fixed, 16, &decode_ipv6/1}

  def column_codec("DateTime(" <> _), do: {:fixed, 4, &decode_datetime/1}
  def column_codec("Enum8(" <> _), do: {:fixed, 1, fn <<v::signed-little-8>> -> v end}
  def column_codec("Enum16(" <> _), do: {:fixed, 2, fn <<v::signed-little-16>> -> v end}
  def column_codec(_), do: :unsupported

  # ClickHouse's plain `DateTime` (and `DateTime(timezone)`, whose wire
  # encoding is identical -- the parameter only affects display/parsing
  # timezone, not storage) is a little-endian `UInt32` Unix-epoch second
  # count (`SELECT toUInt32(now())` matches the raw bytes of a `DateTime`
  # column holding the same instant). There's no fractional-second
  # component -- that's `DateTime64(N)`, not handled here -- so this
  # always decodes to a
  # whole-second `DateTime.t()` in `Etc/UTC` (the epoch itself is
  # timezone-agnostic; `Etc/UTC` is just the zone used to represent it as
  # an Elixir struct, matching how Ecto's built-in `:naive_datetime`/
  # `:utc_datetime` types expect a UTC `DateTime` to load from).
  defp decode_datetime(<<v::unsigned-little-32>>), do: DateTime.from_unix!(v, :second)

  # ClickHouse's `Bool` is stored as a single byte, 0 or 1 (it's literally
  # an alias for `UInt8` constrained to those two values), so this maps
  # non-zero to `true` rather than matching only on `1`.
  defp decode_bool(<<0>>), do: false
  defp decode_bool(<<_nonzero>>), do: true

  @doc """
  Decodes a `DateTime64(P)` tick count of `precision` decimal places into
  a UTC `DateTime.t()`.

  Unlike plain `DateTime`'s unsigned whole-second `UInt32`, `DateTime64`
  is a *signed* little-endian `Int64` count of 10^-P-second ticks since
  the Unix epoch, so it covers pre-epoch instants (negative ticks) as
  well as sub-second resolution.

  Elixir's `DateTime` only carries microsecond resolution, so a precision
  above 6 (e.g. `DateTime64(9)`'s nanoseconds) is truncated -- toward
  negative infinity via `Integer.floor_div/2`, so that a pre-epoch value's
  microsecond remainder stays non-negative and the reconstructed
  `DateTime` is still the correct instant rather than one second off. The
  reported microsecond precision is capped at 6 for the same reason,
  while a lower precision is preserved as-is (a `DateTime64(3)` value
  loads back as `{ms * 1000, 3}`, not silently widened to `6`).
  """
  def decode_datetime64(<<ticks::signed-little-64>>, precision) do
    ticks_per_second = Integer.pow(10, precision)
    seconds = Integer.floor_div(ticks, ticks_per_second)
    remainder = ticks - seconds * ticks_per_second

    microsecond =
      cond do
        precision == 0 -> 0
        precision <= 6 -> remainder * Integer.pow(10, 6 - precision)
        true -> Integer.floor_div(remainder, Integer.pow(10, precision - 6))
      end

    seconds
    |> DateTime.from_unix!(:second)
    |> Map.put(:microsecond, {microsecond, min(precision, 6)})
  end

  # ClickHouse's `Date` is a little-endian `UInt16` count of days since the
  # Unix epoch (1970-01-01) -- `SELECT toUInt16(toDate('1970-01-02'))`
  # returns `1`, matching the raw bytes on the wire. There's no time-of-day
  # or timezone component (that's `DateTime`/`DateTime64`), so this always
  # decodes to a plain `Date.t()`.
  defp decode_date(<<v::unsigned-little-16>>), do: Date.add(~D[1970-01-01], v)

  defp decode_uuid(<<hi::binary-size(8), lo::binary-size(8)>>) do
    hex = Base.encode16(reverse_bytes(hi) <> reverse_bytes(lo), case: :lower)
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
    a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e
  end

  defp reverse_bytes(binary) do
    binary |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
  end

  defp decode_ipv4(<<v::unsigned-little-32>>) do
    <<a::8, b::8, c::8, d::8>> = <<v::unsigned-big-32>>
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp decode_ipv6(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string()
  end

  @doc """
  Reads `num_rows` fixed-width `byte_size`-byte chunks from `binary`,
  running each through `unpack` (e.g. `fn <<v::unsigned-little-32>> -> v
  end`). Returns `{:ok, values, rest}` or `{:incomplete, binary}` if fewer
  than `num_rows * byte_size` bytes are available.
  """
  def decode_fixed_width(binary, num_rows, byte_size, unpack) do
    total = num_rows * byte_size

    case binary do
      <<data::binary-size(total), rest::binary>> ->
        values =
          for <<chunk::binary-size(byte_size) <- data>> do
            unpack.(chunk)
          end

        {:ok, values, rest}

      _ ->
        {:incomplete, binary}
    end
  end

  @doc """
  Reads `remaining` ClickHouse `String` values (varint length prefix +
  bytes) from `binary`. Returns `{:ok, values, rest}` or `{:incomplete,
  binary}`.
  """
  def decode_strings(binary, 0, acc), do: {:ok, Enum.reverse(acc), binary}

  def decode_strings(binary, remaining, acc) do
    case Varint.decode_string(binary) do
      {:ok, value, rest} -> decode_strings(rest, remaining - 1, [value | acc])
      {:incomplete, _} -> {:incomplete, binary}
    end
  end
end
