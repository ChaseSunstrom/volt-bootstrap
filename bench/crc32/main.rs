// crc32: the table-driven CRC-32 of a pseudo-random buffer, a byte at a time
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(256 << 20);
    let mut table = [0u32; 256];
    for (i, t) in table.iter_mut().enumerate() {
        let mut c = i as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 };
        }
        *t = c;
    }
    let mut s: u64 = 1;
    let buf: Vec<u8> = (0..n)
        .map(|_| {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (s >> 56) as u8
        })
        .collect();
    let crc = buf.iter().fold(0xFFFFFFFFu32, |crc, &b| table[((crc ^ b as u32) & 0xFF) as usize] ^ (crc >> 8));
    println!("{:08x}", crc ^ 0xFFFFFFFF);
}
