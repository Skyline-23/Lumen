pub(super) struct BitReader<'a> {
    bytes: &'a [u8],
    bit: usize,
}

impl<'a> BitReader<'a> {
    pub(super) const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, bit: 0 }
    }

    pub(super) fn read_bit(&mut self) -> Result<bool, String> {
        let byte = self
            .bytes
            .get(self.bit / 8)
            .ok_or_else(|| "video SPS is truncated".to_owned())?;
        let value = byte & (1 << (7 - self.bit % 8)) != 0;
        self.bit += 1;
        Ok(value)
    }

    pub(super) fn read_bits(&mut self, count: usize) -> Result<u64, String> {
        if count > 64 {
            return Err("video SPS bit field exceeds 64 bits".to_owned());
        }
        let mut value = 0_u64;
        for _ in 0..count {
            value = value << 1 | u64::from(self.read_bit()?);
        }
        Ok(value)
    }

    pub(super) fn read_unsigned_exp_golomb(&mut self) -> Result<u64, String> {
        let mut leading_zeroes = 0_usize;
        while !self.read_bit()? {
            leading_zeroes += 1;
            if leading_zeroes > 63 {
                return Err("video SPS Exp-Golomb value is oversized".to_owned());
            }
        }
        let suffix = self.read_bits(leading_zeroes)?;
        Ok((1_u64 << leading_zeroes) - 1 + suffix)
    }

    pub(super) fn read_signed_exp_golomb(&mut self) -> Result<i64, String> {
        let code = self.read_unsigned_exp_golomb()?;
        let magnitude = i64::try_from(code.div_ceil(2))
            .map_err(|_| "video SPS signed Exp-Golomb value is oversized".to_owned())?;
        if code % 2 == 0 {
            Ok(-magnitude)
        } else {
            Ok(magnitude)
        }
    }
}

pub(super) fn remove_emulation_prevention(bytes: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(bytes.len());
    let mut zeroes = 0;
    for byte in bytes.iter().copied() {
        if zeroes >= 2 && byte == 3 {
            zeroes = 2;
            continue;
        }
        output.push(byte);
        zeroes = if byte == 0 { zeroes + 1 } else { 0 };
    }
    output
}
