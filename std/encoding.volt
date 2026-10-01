// std::base64 and std::hex: bytes as text and back. Each result goes in the allocator passed (or
// the default one).
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace base64 {
    // why decoding failed
    error decode_error {
        BAD_INPUT, // a character that isn't in the alphabet, a wrong length, or misplaced padding
    }

    internal val STANDARD: str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    internal val URL_SAFE: str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    // data in base64 (RFC 4648), with = padding
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn encode(data: u8[..], allocator: A = {}) -> std::string<A> {
        return encode_with(data, STANDARD, true, move allocator);
    }

    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn encode(text: str, allocator: A = {}) -> std::string<A> {
        return encode_with(@cast<u8[..]>(text), STANDARD, true, move allocator);
    }

    // data in the URL- and file-name-safe alphabet (- and _ for + and /), without padding
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn encode_url(data: u8[..], allocator: A = {}) -> std::string<A> {
        return encode_with(data, URL_SAFE, false, move allocator);
    }

    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn encode_url(text: str, allocator: A = {}) -> std::string<A> {
        return encode_with(@cast<u8[..]>(text), URL_SAFE, false, move allocator);
    }

    // the bytes that base64 text (with its = padding) stands for
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn decode(text: str, allocator: A = {}) -> decode_error!std::vec<u8, A> {
        return decode_with(text, STANDARD, true, move allocator);
    }

    // the bytes that URL-safe base64 text stands for, padded or not
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn decode_url(text: str, allocator: A = {}) -> decode_error!std::vec<u8, A> {
        return decode_with(text, URL_SAFE, false, move allocator);
    }

    <A: std::mem::t_allocator>
    internal fn encode_with(data: u8[..], alphabet: str, pad: bool, allocator: A) -> std::string<A> {
        var out = std::string::new_in(move allocator);
        out.reserve((data.len + 2) / 3 * 4) catch @panic("out of memory");
        var i: usize = 0;
        while (i + 3 <= data.len) {
            val n = (@cast<u32>(data[i]) << 16) | (@cast<u32>(data[i + 1]) << 8) | @cast<u32>(data[i + 2]);
            out.push(alphabet[n >> 18]);
            out.push(alphabet[(n >> 12) & 63]);
            out.push(alphabet[(n >> 6) & 63]);
            out.push(alphabet[n & 63]);
            i += 3;
        }
        val rest = data.len - i;
        if (rest > 0) {
            var n = @cast<u32>(data[i]) << 16;
            if (rest == 2) {
                n = n | (@cast<u32>(data[i + 1]) << 8);
            }
            out.push(alphabet[n >> 18]);
            out.push(alphabet[(n >> 12) & 63]);
            if (rest == 2) {
                out.push(alphabet[(n >> 6) & 63]);
            } else if (pad) {
                out.push('=');
            }
            if (pad) {
                out.push('=');
            }
        }
        return move out;
    }

    // the 6-bit value of c in alphabet, or 64 when it isn't there
    internal fn value_of(c: u8, alphabet: str) -> u32 {
        if (c >= 'A' && c <= 'Z') {
            return @cast<u32>(c - 'A');
        }
        if (c >= 'a' && c <= 'z') {
            return @cast<u32>(c - 'a') + 26;
        }
        if (c >= '0' && c <= '9') {
            return @cast<u32>(c - '0') + 52;
        }
        if (c == alphabet[62]) {
            return 62;
        }
        if (c == alphabet[63]) {
            return 63;
        }
        return 64;
    }

    <A: std::mem::t_allocator>
    internal fn decode_with(text: str, alphabet: str, need_pad: bool, allocator: A) -> decode_error!std::vec<u8, A> {
        // the characters that carry data: padding only at the very end
        var end = text.len;
        var padding: usize = 0;
        while (end > 0 && text[end - 1] == '=' && padding < 2) {
            end -= 1;
            padding += 1;
        }
        if (need_pad && text.len % 4 != 0) {
            return decode_error::BAD_INPUT;
        }
        if (end % 4 == 1 || (padding > 0 && (end + padding) % 4 != 0)) {
            return decode_error::BAD_INPUT;
        }
        var out: std::vec<u8, A> = { allocator: move allocator };
        out.reserve(end / 4 * 3 + 3) catch @panic("out of memory");
        var acc: u32 = 0;
        var bits: u32 = 0;
        for (i) in 0..end {
            val v = value_of(text[i], alphabet);
            if (v == 64) {
                return decode_error::BAD_INPUT;
            }
            acc = (acc << 6) | v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                out.push(@cast<u8>((acc >> bits) & 0xff)) catch @panic("out of memory");
            }
        }
        // the 2 or 4 bits after the last whole byte must be zero: otherwise the same bytes would
        // have more than one spelling
        if ((acc & (0xff >> (8 - bits))) != 0) {
            return decode_error::BAD_INPUT;
        }
        return move out;
    }
}

namespace hex {
    // why decoding failed
    error decode_error {
        BAD_INPUT, // an odd length, or a character that isn't a hex digit
    }

    internal val DIGITS: str = "0123456789abcdef";

    // each byte of data as two lower-case hex digits
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn encode(data: u8[..], allocator: A = {}) -> std::string<A> {
        var out = std::string::new_in(move allocator);
        out.reserve(data.len * 2) catch @panic("out of memory");
        for (b) in data {
            out.push(DIGITS[b >> 4]);
            out.push(DIGITS[b & 15]);
        }
        return move out;
    }

    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn encode(text: str, allocator: A = {}) -> std::string<A> {
        return encode(@cast<u8[..]>(text), move allocator);
    }

    // the bytes hex digits (either case) stand for
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn decode(text: str, allocator: A = {}) -> decode_error!std::vec<u8, A> {
        if (text.len % 2 != 0) {
            return decode_error::BAD_INPUT;
        }
        var out: std::vec<u8, A> = { allocator: move allocator };
        out.reserve(text.len / 2) catch @panic("out of memory");
        var i: usize = 0;
        while (i < text.len) {
            val hi = digit(text[i]);
            val lo = digit(text[i + 1]);
            if (hi > 15 || lo > 15) {
                return decode_error::BAD_INPUT;
            }
            out.push((hi << 4) | lo) catch @panic("out of memory");
            i += 2;
        }
        return move out;
    }

    // a hex digit's value, or 16 for anything else
    internal fn digit(c: u8) -> u8 {
        if (c >= '0' && c <= '9') {
            return c - '0';
        }
        if (c >= 'a' && c <= 'f') {
            return c - 'a' + 10;
        }
        if (c >= 'A' && c <= 'F') {
            return c - 'A' + 10;
        }
        return 16;
    }
}
