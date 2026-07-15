pub(crate) fn expand_masked_color_cursor(
    width: u32,
    height: u32,
    pitch: u32,
    required: u32,
    bytes: &[u8],
) -> Result<Vec<u8>, String> {
    let bytes = validate_color_storage(width, height, pitch, required, bytes)?;
    let width = usize::try_from(width).map_err(|_| "cursor width is too large".to_owned())?;
    let height = usize::try_from(height).map_err(|_| "cursor height is too large".to_owned())?;
    let pitch = usize::try_from(pitch).map_err(|_| "cursor pitch is too large".to_owned())?;
    let mut output = Vec::with_capacity(pixel_storage(width, height)?);
    for row in bytes.chunks_exact(pitch).take(height) {
        for pixel in row.chunks_exact(4).take(width) {
            let [blue, green, red, mask] = <[u8; 4]>::try_from(pixel)
                .map_err(|_| "masked cursor pixel is truncated".to_owned())?;
            if mask != 0 && mask != u8::MAX {
                return Err("masked cursor contains an invalid mask value".to_owned());
            }
            output.extend_from_slice(&[red, green, blue, mask]);
        }
    }
    Ok(output)
}

pub(crate) fn expand_monochrome_cursor(
    width: u32,
    height: u32,
    pitch: u32,
    required: u32,
    bytes: &[u8],
) -> Result<Vec<u8>, String> {
    let minimum_pitch = width.div_ceil(8);
    let mask_bytes = pitch
        .checked_mul(height)
        .ok_or_else(|| "monochrome cursor mask size overflowed".to_owned())?;
    let required_bytes = mask_bytes
        .checked_mul(2)
        .ok_or_else(|| "monochrome cursor storage overflowed".to_owned())?;
    if pitch < minimum_pitch || required_bytes > required {
        return Err("monochrome cursor has invalid mask storage".to_owned());
    }
    let width = usize::try_from(width).map_err(|_| "cursor width is too large".to_owned())?;
    let height = usize::try_from(height).map_err(|_| "cursor height is too large".to_owned())?;
    let pitch = usize::try_from(pitch).map_err(|_| "cursor pitch is too large".to_owned())?;
    let mask_bytes = usize::try_from(mask_bytes)
        .map_err(|_| "monochrome cursor mask is too large".to_owned())?;
    let required_bytes = usize::try_from(required_bytes)
        .map_err(|_| "monochrome cursor storage is too large".to_owned())?;
    let storage = bytes
        .get(..required_bytes)
        .ok_or_else(|| "monochrome cursor buffer is truncated".to_owned())?;
    let (and_mask, xor_mask) = storage.split_at(mask_bytes);
    let mut output = Vec::with_capacity(pixel_storage(width, height)?);
    for y in 0..height {
        for x in 0..width {
            let byte_index = y
                .checked_mul(pitch)
                .and_then(|row| row.checked_add(x / 8))
                .ok_or_else(|| "cursor mask index overflowed".to_owned())?;
            let bit = 0x80_u8 >> (x % 8);
            output.extend_from_slice(&[
                u8::from(and_mask[byte_index] & bit != 0) * u8::MAX,
                u8::from(xor_mask[byte_index] & bit != 0) * u8::MAX,
                0,
                u8::MAX,
            ]);
        }
    }
    Ok(output)
}

fn validate_color_storage(
    width: u32,
    height: u32,
    pitch: u32,
    required: u32,
    bytes: &[u8],
) -> Result<Vec<u8>, String> {
    let minimum_pitch = width
        .checked_mul(4)
        .ok_or_else(|| "cursor row pitch overflowed".to_owned())?;
    let required_bytes = pitch
        .checked_mul(height)
        .ok_or_else(|| "cursor shape size overflowed".to_owned())?;
    if pitch < minimum_pitch || required_bytes > required {
        return Err("color cursor shape has invalid row storage".to_owned());
    }
    let required_bytes = usize::try_from(required_bytes)
        .map_err(|_| "cursor shape storage is too large".to_owned())?;
    bytes
        .get(..required_bytes)
        .map(|storage| storage.to_vec())
        .ok_or_else(|| "cursor shape buffer is truncated".to_owned())
}

fn pixel_storage(width: usize, height: usize) -> Result<usize, String> {
    width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| "cursor pixel storage overflowed".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_monochrome_and_xor_planes_into_shader_channels() {
        let expanded = expand_monochrome_cursor(4, 1, 1, 2, &[0b1010_0000, 0b0110_0000]).unwrap();
        assert_eq!(
            expanded,
            vec![255, 0, 0, 255, 0, 255, 0, 255, 255, 255, 0, 255, 0, 0, 0, 255,]
        );
    }

    #[test]
    fn converts_masked_bgra_to_rgba_and_rejects_non_binary_masks() {
        assert_eq!(
            expand_masked_color_cursor(2, 1, 8, 8, &[1, 2, 3, 0, 4, 5, 6, 255]).unwrap(),
            vec![3, 2, 1, 0, 6, 5, 4, 255]
        );
        assert!(expand_masked_color_cursor(1, 1, 4, 4, &[1, 2, 3, 127]).is_err());
    }

    #[test]
    fn rejects_truncated_cursor_planes_before_expansion() {
        assert!(expand_monochrome_cursor(9, 1, 1, 2, &[0, 0]).is_err());
        assert!(expand_monochrome_cursor(8, 2, 1, 4, &[0, 0, 0]).is_err());
        assert!(expand_masked_color_cursor(2, 1, 8, 8, &[0; 7]).is_err());
    }
}
