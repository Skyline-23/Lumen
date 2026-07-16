use std::collections::BTreeMap;

use windows_sys::Win32::Devices::Display::{
    DISPLAYCONFIG_2DREGION, DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_MODE_INFO_0,
    DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE, DISPLAYCONFIG_MODE_INFO_TYPE_TARGET,
    DISPLAYCONFIG_PATH_INFO, DISPLAYCONFIG_PATH_SOURCE_INFO_0, DISPLAYCONFIG_PATH_TARGET_INFO_0,
    DISPLAYCONFIG_RATIONAL, DISPLAYCONFIG_SOURCE_MODE, DISPLAYCONFIG_TARGET_MODE,
    DISPLAYCONFIG_VIDEO_SIGNAL_INFO, DISPLAYCONFIG_VIDEO_SIGNAL_INFO_0,
};
use windows_sys::Win32::Foundation::{LUID, POINTL};
use windows_sys::Win32::Graphics::Gdi::DISPLAYCONFIG_PATH_MODE_IDX_INVALID;

use super::display_topology::{
    AdapterLuid, RationalValue, SourceModeValue, TargetModeValue, WindowsDisplayConfigSnapshot,
    WindowsPathRecord,
};

type ModeKey = (i32, i32, u32, u32);

pub(super) fn native_arrays(
    snapshot: &WindowsDisplayConfigSnapshot,
) -> Result<(Vec<DISPLAYCONFIG_PATH_INFO>, Vec<DISPLAYCONFIG_MODE_INFO>), String> {
    let mut modes = Vec::new();
    let mut mode_indices = BTreeMap::new();
    let mut paths = Vec::with_capacity(snapshot.paths.len());
    for record in &snapshot.paths {
        let source_index = record
            .source_mode
            .map(|mode| source_mode_index(record, mode, &mut modes, &mut mode_indices))
            .transpose()?
            .unwrap_or(DISPLAYCONFIG_PATH_MODE_IDX_INVALID);
        let target_index = record
            .target_mode
            .map(|mode| target_mode_index(record, mode, &mut modes, &mut mode_indices))
            .transpose()?
            .unwrap_or(DISPLAYCONFIG_PATH_MODE_IDX_INVALID);
        let mut path = DISPLAYCONFIG_PATH_INFO::default();
        path.sourceInfo.adapterId = native_luid(record.source_adapter);
        path.sourceInfo.id = record.source_id;
        path.sourceInfo.Anonymous = DISPLAYCONFIG_PATH_SOURCE_INFO_0 {
            modeInfoIdx: source_index,
        };
        path.sourceInfo.statusFlags = record.source_status_flags;
        path.targetInfo.adapterId = native_luid(record.target_adapter);
        path.targetInfo.id = record.target_id;
        path.targetInfo.Anonymous = DISPLAYCONFIG_PATH_TARGET_INFO_0 {
            modeInfoIdx: target_index,
        };
        path.targetInfo.outputTechnology = record.output_technology;
        path.targetInfo.rotation = record.rotation;
        path.targetInfo.scaling = record.scaling;
        path.targetInfo.refreshRate = native_rational(record.refresh_rate);
        path.targetInfo.scanLineOrdering = record.scan_line_ordering;
        path.targetInfo.targetAvailable = i32::from(record.target_available);
        path.targetInfo.statusFlags = record.target_status_flags;
        path.flags = record.path_flags;
        paths.push(path);
    }
    Ok((paths, modes))
}

fn source_mode_index(
    record: &WindowsPathRecord,
    mode: SourceModeValue,
    modes: &mut Vec<DISPLAYCONFIG_MODE_INFO>,
    indices: &mut BTreeMap<ModeKey, u32>,
) -> Result<u32, String> {
    insert_mode(
        DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE,
        record.source_adapter,
        record.source_id,
        DISPLAYCONFIG_MODE_INFO_0 {
            sourceMode: DISPLAYCONFIG_SOURCE_MODE {
                width: mode.width,
                height: mode.height,
                pixelFormat: mode.pixel_format,
                position: POINTL {
                    x: mode.position_x,
                    y: mode.position_y,
                },
            },
        },
        modes,
        indices,
    )
}

fn target_mode_index(
    record: &WindowsPathRecord,
    mode: TargetModeValue,
    modes: &mut Vec<DISPLAYCONFIG_MODE_INFO>,
    indices: &mut BTreeMap<ModeKey, u32>,
) -> Result<u32, String> {
    let signal = DISPLAYCONFIG_VIDEO_SIGNAL_INFO {
        pixelRate: mode.pixel_rate,
        hSyncFreq: native_rational(mode.horizontal_sync),
        vSyncFreq: native_rational(mode.vertical_sync),
        activeSize: DISPLAYCONFIG_2DREGION {
            cx: mode.active_size[0],
            cy: mode.active_size[1],
        },
        totalSize: DISPLAYCONFIG_2DREGION {
            cx: mode.total_size[0],
            cy: mode.total_size[1],
        },
        Anonymous: DISPLAYCONFIG_VIDEO_SIGNAL_INFO_0 {
            videoStandard: mode.video_standard,
        },
        scanLineOrdering: mode.scan_line_ordering,
    };
    insert_mode(
        DISPLAYCONFIG_MODE_INFO_TYPE_TARGET,
        record.target_adapter,
        record.target_id,
        DISPLAYCONFIG_MODE_INFO_0 {
            targetMode: DISPLAYCONFIG_TARGET_MODE {
                targetVideoSignalInfo: signal,
            },
        },
        modes,
        indices,
    )
}

fn insert_mode(
    kind: i32,
    adapter: AdapterLuid,
    id: u32,
    value: DISPLAYCONFIG_MODE_INFO_0,
    modes: &mut Vec<DISPLAYCONFIG_MODE_INFO>,
    indices: &mut BTreeMap<ModeKey, u32>,
) -> Result<u32, String> {
    let key = (kind, adapter.high_part, adapter.low_part, id);
    if let Some(index) = indices.get(&key) {
        return Ok(*index);
    }
    let index = u32::try_from(modes.len()).map_err(|_| "Windows mode count overflowed")?;
    modes.push(DISPLAYCONFIG_MODE_INFO {
        infoType: kind,
        id,
        adapterId: native_luid(adapter),
        Anonymous: value,
    });
    indices.insert(key, index);
    Ok(index)
}

const fn native_luid(value: AdapterLuid) -> LUID {
    LUID {
        LowPart: value.low_part,
        HighPart: value.high_part,
    }
}

const fn native_rational(value: RationalValue) -> DISPLAYCONFIG_RATIONAL {
    DISPLAYCONFIG_RATIONAL {
        Numerator: value.numerator,
        Denominator: value.denominator,
    }
}
