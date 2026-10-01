// flags: --leak-check
use std::io;
use std::string;
use std::text;
// std::base64, std::hex and std::digest against their published test vectors (RFC 4648, the CRC-32
// check value, FNV-1a's, FIPS 180-4's SHA-256 examples), and where text stops being UTF-8

// base64 text decoded, or the error, in brackets
fn decoded(text: str) -> std::string {
    var out = std::string::from("[");
    val bytes = std::base64::decode(text) catch |e| {
        std::fmt::write(&out, "{}]", e);
        return move out;
    };
    out.append(@cast<str>(bytes.items()));
    out.push(']');
    return move out;
}

fn hex_status(text: str) -> std::string {
    val bytes = std::hex::decode(text) catch |e| {
        return std::string::from("BAD_INPUT");
    };
    return std::string::from(@cast<str>(bytes.items()));
}

fn sha(data: str) -> std::string {
    val d = std::digest::sha256_of(data);
    return std::hex::encode(d[..]);
}

fn main() -> !void {
    // base64: RFC 4648's vectors both ways
    val words: str[7] = { "", "f", "fo", "foo", "foob", "fooba", "foobar" };
    var enc = std::string::from("|");
    var dec = std::string::from("");
    for (w) in words {
        val e = std::base64::encode(w);
        enc.append(e.as_str());
        enc.push('|');
        dec.append(decoded(e.as_str()).as_str());
    }
    std::println(enc.as_str());
    std::println(dec.as_str());
    // bad input: a stray character, a wrong length, padding in the middle, leftover bits that
    // aren't zero ("Zh==" would be another spelling of "f")
    std::println("{}{}{}{}", decoded("Zm9v!").as_str(), decoded("Zm9").as_str(), decoded("Zg==Zg==").as_str(), decoded("Zh==").as_str());
    // URL-safe: - and _ instead of + and /, no padding
    val raw: u8[] = { 0xfb, 0xff, 0xbf, 0x3e };
    val std_form = std::base64::encode(raw[..]);
    val url_form = std::base64::encode_url(raw[..]);
    val back = try std::base64::decode_url(url_form.as_str());
    std::println("{} {} {}", std_form.as_str(), url_form.as_str(), back.items());

    // hex: lower case out, either case in
    val h = std::hex::encode("Hello");
    std::println("{} {} {}", h.as_str(), hex_status("48656C6c6f").as_str(), hex_status("abc").as_str());

    // CRC-32 (as zip and PNG use it) and 64-bit FNV-1a
    std::println("{:x} {:x} {:x} {:x} {:x}", std::digest::crc32("123456789"), std::digest::crc32(""), std::digest::fnv1a(""), std::digest::fnv1a("a"), std::digest::fnv1a("foobar"));

    // SHA-256: one call, and fed in pieces
    std::println(sha("").as_str());
    std::println(sha("abc").as_str());
    std::println(sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").as_str());
    var h256 = std::digest::sha256::new();
    var piece: u8[997];
    for (i) in 0..997 {
        piece[i] = 'a';
    }
    var left: usize = 1000000;
    while (left > 0) {
        var n: usize = 997;
        if (left < n) {
            n = left;
        }
        h256.update(piece[0..n]);
        left -= n;
    }
    val million = h256.finish();
    std::println(std::hex::encode(million[..]).as_str());

    // UTF-8: where the first byte that isn't part of a character is
    val good: u8[] = { 'o', 'k', 0xC3, 0xA9 };
    val stray: u8[] = { 'a', 'b', 0xFF, 'c' };
    val cut: u8[] = { 0xE2, 0x82 };
    val g = @cast<str>(good[..]);
    val s = @cast<str>(stray[..]);
    val c = @cast<str>(cut[..]);
    std::println("{} {} {}", g.utf8_error() ?? 99, s.utf8_error() ?? 99, c.utf8_error() ?? 99);
}
// expect: ||Zg==|Zm8=|Zm9v|Zm9vYg==|Zm9vYmE=|Zm9vYmFy|
// expect: [][f][fo][foo][foob][fooba][foobar]
// expect: [BAD_INPUT][BAD_INPUT][BAD_INPUT][BAD_INPUT]
// expect: +/+/Pg== -_-_Pg { 251, 255, 191, 62 }
// expect: 48656c6c6f Hello BAD_INPUT
// expect: cbf43926 0 cbf29ce484222325 af63dc4c8601ec8c 85944171f73967e8
// expect: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
// expect: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
// expect: 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
// expect: cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0
// expect: 99 2 0
