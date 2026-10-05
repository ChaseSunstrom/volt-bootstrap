---
title: Encoding and hashing
description: std::base64, std::hex and std::digest (CRC-32, FNV-1a, SHA-256), and checking text is UTF-8.
sidebar:
  order: 8
---

## Base64 and hex

`std::base64::encode` writes bytes (a `u8[..]` or a `str`) as base64 text, as RFC 4648 describes,
with `=` padding. `encode_url` uses `-` and `_` instead of `+` and `/` and leaves the padding
off, so the result is safe in URLs and file names. `decode` and `decode_url` give the bytes back
in a `std::vec<u8>`. Text that isn't valid base64 fails with `BAD_INPUT`: a character that isn't
in the alphabet, a wrong length, padding in the wrong place, or unused bits at the end that aren't
zero (so bytes have only one spelling). `decode_url` accepts the text with or without padding.

`std::hex::encode` writes two lower-case digits a byte. `decode` accepts either case, and fails
with `BAD_INPUT` on an odd length or a character that isn't a hex digit.

```volt
use std::io;

fn main() -> !void {
    val b = std::base64::encode("hello, volt");
    val back = try std::base64::decode(b.as_str());
    std::println("{} {}", b.as_str(), @cast<str>(back.items()));
    val h = std::hex::encode("hi");
    std::println("{} {}", h.as_str(), (try std::hex::decode("4A4b")).items());
    val bad = std::base64::decode("no!") catch |e| {
        std::println("{}", e);
        return;
    };
}
// expect: aGVsbG8sIHZvbHQ= hello, volt
// expect: 6869 { 74, 75 }
// expect: BAD_INPUT
```

Like other std functions that make something, each takes an optional allocator as its last
argument, and the result uses it (see [Allocators](/volt-bootstrap/std/allocators/)).

## Checksums and hashes

`std::digest` has three, each taking a `u8[..]` or a `str`:
- `crc32(data) -> u32`: the CRC-32 that zip, gzip and PNG use.
- `fnv1a(data) -> u64`: 64-bit FNV-1a. It's fast, which suits hash tables and fingerprints, but don't
  use it for anything an attacker controls.
- `sha256_of(data) -> u8[32]`: SHA-256 (FIPS 180-4).

For data that comes in pieces, make a hasher with `std::digest::sha256::new()`, `update` it with
each piece, then `finish` it for the digest. A hasher that has finished is used up: make a new
one for more data.

```volt
use std::io;

fn main() -> void {
    std::println("{:x} {:x}", std::digest::crc32("123456789"), std::digest::fnv1a("volt"));
    val once = std::digest::sha256_of("abc");
    var h = std::digest::sha256::new();
    h.update("a");
    h.update("bc");
    val pieces = h.finish();
    val text = std::hex::encode(pieces[..]);
    val same = std::hex::encode(once[..]).as_str() == text.as_str();
    std::println("{} {}", text.as_str(), same);
}
// expect: cbf43926 317deb00e383702a
// expect: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad true
```

## Checking UTF-8

A `str` is meant to hold UTF-8, but text from outside (a file, a socket, a C library) might not.
`utf8_error()` returns where the first byte that isn't part of a valid character is: a stray
byte, an overlong or cut-off sequence, or a surrogate. It returns `null` when all of the text is
valid. `is_utf8()` asks only whether it is valid.

```volt
use std::io;
use std::text;

fn main() -> void {
    val bytes: u8[] = { 'v', 'o', 0xC3, 0xA9, 0xFF, 't' };
    val s = @cast<str>(bytes[..]);
    std::println("{} {}", s.utf8_error() ?? 99, "volt".utf8_error() ?? 99);
}
// expect: 4 99
```
