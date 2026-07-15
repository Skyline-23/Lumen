use std::ptr::null_mut;

use windows_sys::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, GetDisplayConfigBufferSizes, QueryDisplayConfig, SetDisplayConfig,
    DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO, DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO,
    DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE,
    DISPLAYCONFIG_MODE_INFO_TYPE_TARGET, DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_RATIONAL,
    QDC_ONLY_ACTIVE_PATHS, SDC_APPLY, SDC_NO_OPTIMIZATION, SDC_SAVE_TO_DATABASE,
    SDC_USE_SUPPLIED_DISPLAY_CONFIG,
};
use windows_sys::Win32::Foundation::{ERROR_SUCCESS, LUID};
use windows_sys::Win32::Graphics::Gdi::DISPLAYCONFIG_PATH_MODE_IDX_INVALID;

use super::display_topology::{
    AdapterLuid, RationalValue, SourceModeValue, TargetModeValue, WindowsDisplayConfigSnapshot,
    WindowsPathRecord,
};
use super::native_display_topology_apply::native_arrays;

pub(super) fn query_active_topology() -> Result<WindowsDisplayConfigSnapshot, String> {
    let mut path_count = 0;
    let mut mode_count = 0;
    // SAFETY: Category 8 (FFI boundary). Both count pointers reference live writable u32 values.
    let status = unsafe {
        GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut path_count, &mut mode_count)
    };
    if status != ERROR_SUCCESS {
        return Err(format!("Windows display buffer query failed: {status}"));
    }
    let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); path_count as usize];
    let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); mode_count as usize];
    // SAFETY: Category 8 (FFI boundary). The vectors provide the capacities returned by
    // GetDisplayConfigBufferSizes and remain exclusively borrowed for this call.
    let status = unsafe {
        QueryDisplayConfig(
            QDC_ONLY_ACTIVE_PATHS,
            &mut path_count,
            paths.as_mut_ptr(),
            &mut mode_count,
            modes.as_mut_ptr(),
            null_mut(),
        )
    };
    if status != ERROR_SUCCESS {
        return Err(format!("Windows active display query failed: {status}"));
    }
    paths.truncate(path_count as usize);
    modes.truncate(mode_count as usize);
    let records = paths
        .iter()
        .map(|path| path_record(path, &modes))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(WindowsDisplayConfigSnapshot { paths: records })
}

pub(super) fn apply_topology(snapshot: &WindowsDisplayConfigSnapshot) -> Result<(), String> {
    if snapshot.paths.is_empty() {
        return Err("Windows refused to apply an empty display topology".to_owned());
    }
    let (paths, modes) = native_arrays(snapshot)?;
    // SAFETY: Category 8 (FFI boundary). Both arrays remain live and immutable for the call,
    // and every path mode index was built against the supplied mode array.
    let status = unsafe {
        SetDisplayConfig(
            u32::try_from(paths.len()).map_err(|_| "Windows display path count overflowed")?,
            paths.as_ptr(),
            u32::try_from(modes.len()).map_err(|_| "Windows display mode count overflowed")?,
            modes.as_ptr(),
            SDC_APPLY
                | SDC_USE_SUPPLIED_DISPLAY_CONFIG
                | SDC_SAVE_TO_DATABASE
                | SDC_NO_OPTIMIZATION,
        )
    };
    (status == ERROR_SUCCESS as i32)
        .then_some(())
        .ok_or_else(|| format!("Windows rejected the exact supplied display topology: {status}"))
}

pub(super) fn verify_topology(expected: &WindowsDisplayConfigSnapshot) -> Result<(), String> {
    let mut expected = expected.clone();
    let mut actual = query_active_topology()?;
    sort_paths(&mut expected.paths);
    sort_paths(&mut actual.paths);
    (actual == expected)
        .then_some(())
        .ok_or_else(|| "Windows display topology verification did not match the journal".to_owned())
}

fn path_record(
    path: &DISPLAYCONFIG_PATH_INFO,
    modes: &[DISPLAYCONFIG_MODE_INFO],
) -> Result<WindowsPathRecord, String> {
    // SAFETY: Category 5 (union validity). QueryDisplayConfig populated the non-virtual-aware
    // path, so modeInfoIdx is the active union member for source and target information.
    let source_index = unsafe { path.sourceInfo.Anonymous.modeInfoIdx };
    // SAFETY: Category 5 (union validity). The same QueryDisplayConfig contract selects
    // modeInfoIdx as the target union member when QDC_VIRTUAL_MODE_AWARE is absent.
    let target_index = unsafe { path.targetInfo.Anonymous.modeInfoIdx };
    Ok(WindowsPathRecord {
        source_adapter: luid_value(path.sourceInfo.adapterId),
        source_id: path.sourceInfo.id,
        source_status_flags: path.sourceInfo.statusFlags,
        source_mode: source_mode(modes, source_index)?,
        target_adapter: luid_value(path.targetInfo.adapterId),
        target_id: path.targetInfo.id,
        output_technology: path.targetInfo.outputTechnology,
        rotation: path.targetInfo.rotation,
        scaling: path.targetInfo.scaling,
        refresh_rate: rational_value(path.targetInfo.refreshRate),
        scan_line_ordering: path.targetInfo.scanLineOrdering,
        target_available: path.targetInfo.targetAvailable != 0,
        target_status_flags: path.targetInfo.statusFlags,
        target_mode: target_mode(modes, target_index)?,
        path_flags: path.flags,
        bit_depth: target_bit_depth(path),
    })
}

fn source_mode(
    modes: &[DISPLAYCONFIG_MODE_INFO],
    index: u32,
) -> Result<Option<SourceModeValue>, String> {
    if index == DISPLAYCONFIG_PATH_MODE_IDX_INVALID {
        return Ok(None);
    }
    let mode = modes
        .get(index as usize)
        .filter(|mode| mode.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE)
        .ok_or_else(|| "Windows source mode index is invalid".to_owned())?;
    // SAFETY: Category 5 (union validity). infoType was checked as SOURCE immediately above.
    let value = unsafe { mode.Anonymous.sourceMode };
    Ok(Some(SourceModeValue {
        width: value.width,
        height: value.height,
        pixel_format: value.pixelFormat,
        position_x: value.position.x,
        position_y: value.position.y,
    }))
}

fn target_mode(
    modes: &[DISPLAYCONFIG_MODE_INFO],
    index: u32,
) -> Result<Option<TargetModeValue>, String> {
    if index == DISPLAYCONFIG_PATH_MODE_IDX_INVALID {
        return Ok(None);
    }
    let mode = modes
        .get(index as usize)
        .filter(|mode| mode.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_TARGET)
        .ok_or_else(|| "Windows target mode index is invalid".to_owned())?;
    // SAFETY: Category 5 (union validity). infoType was checked as TARGET immediately above.
    let signal = unsafe { mode.Anonymous.targetMode.targetVideoSignalInfo };
    Ok(Some(TargetModeValue {
        pixel_rate: signal.pixelRate,
        horizontal_sync: rational_value(signal.hSyncFreq),
        vertical_sync: rational_value(signal.vSyncFreq),
        active_size: [signal.activeSize.cx, signal.activeSize.cy],
        total_size: [signal.totalSize.cx, signal.totalSize.cy],
        // SAFETY: Category 5 (union validity). QueryDisplayConfig initializes the video signal
        // union and videoStandard is the lossless raw representation used for round-trip restore.
        video_standard: unsafe { signal.Anonymous.videoStandard },
        scan_line_ordering: signal.scanLineOrdering,
    }))
}

fn target_bit_depth(path: &DISPLAYCONFIG_PATH_INFO) -> u8 {
    let mut info = DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO::default();
    info.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
    info.header.size = std::mem::size_of::<DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO>() as u32;
    info.header.adapterId = path.targetInfo.adapterId;
    info.header.id = path.targetInfo.id;
    // SAFETY: Category 8 (FFI boundary). The header is initialized with the exact structure size
    // and target identity, and remains live and exclusively writable for the call.
    let status = unsafe { DisplayConfigGetDeviceInfo(&mut info.header) };
    (status == ERROR_SUCCESS as i32)
        .then(|| u8::try_from(info.bitsPerColorChannel).ok())
        .flatten()
        .unwrap_or(0)
}

fn sort_paths(paths: &mut [WindowsPathRecord]) {
    paths.sort_by_key(|path| {
        (
            path.target_adapter,
            path.target_id,
            path.source_adapter,
            path.source_id,
        )
    });
}

const fn luid_value(value: LUID) -> AdapterLuid {
    AdapterLuid {
        high_part: value.HighPart,
        low_part: value.LowPart,
    }
}

const fn rational_value(value: DISPLAYCONFIG_RATIONAL) -> RationalValue {
    RationalValue {
        numerator: value.Numerator,
        denominator: value.Denominator,
    }
}
