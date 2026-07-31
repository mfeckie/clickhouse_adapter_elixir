use rustler::{Binary, Encoder, Env, OwnedBinary, Term};

mod atoms {
    rustler::atoms! {
        ok,
        error
    }
}

/// Raw LZ4 block compression (liblz4 "block format", not the LZ4 Frame
/// format). This matches what ClickHouse's native protocol wraps in its own
/// checksum+method+sizes envelope.
#[rustler::nif]
fn lz4_compress<'a>(env: Env<'a>, data: Binary<'a>) -> Binary<'a> {
    let compressed = lz4_flex::block::compress(data.as_slice());
    binary_from_vec(env, compressed)
}

/// Raw LZ4 block decompression. `uncompressed_size` must be known up front
/// (from ClickHouse's block header) since the raw block format carries no
/// length prefix of its own.
#[rustler::nif]
fn lz4_decompress<'a>(env: Env<'a>, data: Binary<'a>, uncompressed_size: usize) -> Term<'a> {
    match lz4_flex::block::decompress(data.as_slice(), uncompressed_size) {
        Ok(decompressed) => (atoms::ok(), binary_from_vec(env, decompressed)).encode(env),
        Err(err) => (atoms::error(), err.to_string()).encode(env),
    }
}

/// CityHash v1.0.2 128-bit hash, byte-packed the way ClickHouse writes it on
/// the wire: `pair.first` as 8 little-endian bytes, followed by `pair.second`
/// as 8 little-endian bytes.
///
/// ClickHouse's own wire checksum for compressed blocks is computed with its
/// vendored v1.0.2 CityHash (contrib/cityhash102 in ClickHouse's own source)
/// -- a different, older algorithm than v1.0.3, not just a different
/// byte-packing of the same hash. v1.0.2 and v1.0.3 only agree for short
/// inputs; they diverge once the input exceeds roughly 64 bytes, so using
/// the wrong version here silently "works" for tiny blocks and produces a
/// checksum mismatch for any real, larger result set.
///
/// This is NOT the same as `u128::to_le_bytes()` on the crate's return value
/// -- the crate packs `first` into the high 64 bits and `second` into the low
/// 64 bits of the u128 (see cityhash_102_128's `u128::from_be_bytes` call),
/// so a naive to_le_bytes() would emit `second` before `first`, the reverse
/// of ClickHouse's wire order.
#[rustler::nif]
fn cityhash128<'a>(env: Env<'a>, data: Binary<'a>) -> Binary<'a> {
    let value = cityhash_rs::cityhash_102_128(data.as_slice());
    binary_from_vec(env, pack_wire_128(value).to_vec())
}

/// Packs a cityhash-rs u128 result into ClickHouse's on-wire checksum byte
/// order: `first` (the high 64 bits of the crate's u128) as little-endian
/// bytes, then `second` (the low 64 bits) as little-endian bytes.
fn pack_wire_128(value: u128) -> [u8; 16] {
    let first = (value >> 64) as u64;
    let second = value as u64;

    let mut out = [0u8; 16];
    out[0..8].copy_from_slice(&first.to_le_bytes());
    out[8..16].copy_from_slice(&second.to_le_bytes());
    out
}

fn binary_from_vec(env: Env<'_>, bytes: Vec<u8>) -> Binary<'_> {
    let mut owned = OwnedBinary::new(bytes.len()).expect("failed to allocate binary");
    owned.as_mut_slice().copy_from_slice(&bytes);
    owned.release(env)
}

rustler::init!("Elixir.ChCodec.Native");

#[cfg(test)]
mod tests {
    use super::pack_wire_128;

    // Cross-checked against cityhash-rs's own port of Google's official
    // CityHash v1.0.3 test suite (test_103.rs, first row, empty input):
    // expected[3] = first = 0x3df09dfc64c09a2b, expected[4] = second = 0x3cb540c392e51e29.
    #[test]
    fn cityhash_103_empty_input_matches_known_vector() {
        let value = cityhash_rs::cityhash_103_128(&[]);
        assert_eq!((value >> 64) as u64, 0x3df09dfc64c09a2b);
        assert_eq!(value as u64, 0x3cb540c392e51e29);

        let wire = pack_wire_128(value);
        assert_eq!(
            wire,
            [
                0x2b, 0x9a, 0xc0, 0x64, 0xfc, 0x9d, 0xf0, 0x3d, 0x29, 0x1e, 0xe5, 0x92, 0xc3,
                0x40, 0xb5, 0x3c,
            ]
        );
    }

    // Cross-checked against cityhash-rs's own port of Google's official
    // CityHash v1.0.2 test suite (test_102.rs, first row, empty input):
    // expected[3] = first = 0x3df09dfc64c09a2b, expected[4] = second = 0x3cb540c392e51e29.
    // This is the version actually used by `cityhash128/1` (the NIF ClickHouse
    // block checksums go through) -- the empty-input vector happens to match
    // v1.0.3's, but that's a coincidence of the seed constants, not something
    // that holds for longer inputs (see the crate's divergence above ~64 bytes).
    #[test]
    fn cityhash_102_empty_input_matches_known_vector() {
        let value = cityhash_rs::cityhash_102_128(&[]);
        assert_eq!((value >> 64) as u64, 0x3df09dfc64c09a2b);
        assert_eq!(value as u64, 0x3cb540c392e51e29);

        let wire = pack_wire_128(value);
        assert_eq!(
            wire,
            [
                0x2b, 0x9a, 0xc0, 0x64, 0xfc, 0x9d, 0xf0, 0x3d, 0x29, 0x1e, 0xe5, 0x92, 0xc3,
                0x40, 0xb5, 0x3c,
            ]
        );
    }

    #[test]
    fn lz4_round_trips() {
        let input = b"the quick brown fox jumps over the lazy dog, the quick brown fox jumps over the lazy dog";
        let compressed = lz4_flex::block::compress(input);
        let decompressed = lz4_flex::block::decompress(&compressed, input.len()).unwrap();
        assert_eq!(decompressed, input);
    }
}
