use lumen_engine::{
    PhysicalDisplayMode, PhysicalDisplayState, PhysicalDisplayTopology, WindowsAdapterLuid,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub(super) struct AdapterLuid {
    #[serde(rename = "h")]
    pub high_part: i32,
    #[serde(rename = "l")]
    pub low_part: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct RationalValue {
    #[serde(rename = "n")]
    pub numerator: u32,
    #[serde(rename = "d")]
    pub denominator: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct SourceModeValue {
    #[serde(rename = "w")]
    pub width: u32,
    #[serde(rename = "h")]
    pub height: u32,
    #[serde(rename = "f")]
    pub pixel_format: i32,
    #[serde(rename = "x")]
    pub position_x: i32,
    #[serde(rename = "y")]
    pub position_y: i32,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct TargetModeValue {
    #[serde(rename = "p")]
    pub pixel_rate: u64,
    #[serde(rename = "h")]
    pub horizontal_sync: RationalValue,
    #[serde(rename = "v")]
    pub vertical_sync: RationalValue,
    #[serde(rename = "a")]
    pub active_size: [u32; 2],
    #[serde(rename = "t")]
    pub total_size: [u32; 2],
    #[serde(rename = "s")]
    pub video_standard: u32,
    #[serde(rename = "o")]
    pub scan_line_ordering: i32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct WindowsPathRecord {
    #[serde(rename = "sa")]
    pub source_adapter: AdapterLuid,
    #[serde(rename = "si")]
    pub source_id: u32,
    #[serde(rename = "sf")]
    pub source_status_flags: u32,
    #[serde(rename = "sm")]
    pub source_mode: Option<SourceModeValue>,
    #[serde(rename = "ta")]
    pub target_adapter: AdapterLuid,
    #[serde(rename = "ti")]
    pub target_id: u32,
    #[serde(rename = "ot")]
    pub output_technology: i32,
    #[serde(rename = "r")]
    pub rotation: i32,
    #[serde(rename = "sc")]
    pub scaling: i32,
    #[serde(rename = "rr")]
    pub refresh_rate: RationalValue,
    #[serde(rename = "so")]
    pub scan_line_ordering: i32,
    #[serde(rename = "av")]
    pub target_available: bool,
    #[serde(rename = "tf")]
    pub target_status_flags: u32,
    #[serde(rename = "tm")]
    pub target_mode: Option<TargetModeValue>,
    #[serde(rename = "pf")]
    pub path_flags: u32,
    #[serde(rename = "b")]
    pub bit_depth: u8,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(super) struct WindowsPathIdentity {
    pub adapter: AdapterLuid,
    pub target_id: u32,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct WindowsDisplayConfigSnapshot {
    pub paths: Vec<WindowsPathRecord>,
}

impl WindowsDisplayConfigSnapshot {
    pub(super) fn to_physical_topology(&self) -> Result<PhysicalDisplayTopology, String> {
        if self.paths.is_empty() {
            return Err("Windows physical display topology is empty".to_owned());
        }
        let mut sources = BTreeMap::new();
        let mut displays = Vec::with_capacity(self.paths.len());
        let mut records = Vec::with_capacity(self.paths.len());
        for path in &self.paths {
            let source_mode = path
                .source_mode
                .ok_or_else(|| "Windows physical display source mode is missing".to_owned())?;
            if path.refresh_rate.denominator == 0 {
                return Err("Windows physical display refresh denominator is zero".to_owned());
            }
            let id = display_id(path.target_adapter, path.target_id);
            let source_key = (path.source_adapter, path.source_id);
            let mirror_master_id = sources.get(&source_key).cloned();
            sources.entry(source_key).or_insert_with(|| id.clone());
            displays.push(PhysicalDisplayState {
                id,
                vendor_id: None,
                product_id: None,
                serial_number: None,
                builtin: None,
                mode: PhysicalDisplayMode {
                    width: source_mode.width,
                    height: source_mode.height,
                    refresh_millihz: path
                        .refresh_rate
                        .numerator
                        .checked_mul(1_000)
                        .ok_or_else(|| "Windows physical refresh rate overflowed".to_owned())?
                        / path.refresh_rate.denominator,
                    bit_depth: path.bit_depth,
                },
                origin_x: source_mode.position_x,
                origin_y: source_mode.position_y,
                mirror_master_id,
                enabled: true,
                active: true,
                online: path.target_available,
            });
            let record = serde_json::to_string(path)
                .map_err(|_| "Windows display path serialization failed".to_owned())?;
            if record.len() > 512 {
                return Err("Windows display recovery path exceeds the bounded payload".to_owned());
            }
            records.push(record);
        }
        let first_adapter = self.paths[0].source_adapter;
        serde_json::from_value(serde_json::json!({
            "displays": displays,
            "windows_adapter_luid": WindowsAdapterLuid {
                high_part: first_adapter.high_part,
                low_part: first_adapter.low_part,
            },
            "windows_target_paths": records,
        }))
        .map_err(|_| "Windows physical topology payload construction failed".to_owned())
    }

    pub(super) fn from_physical_topology(
        topology: &PhysicalDisplayTopology,
    ) -> Result<Self, String> {
        if topology.windows_target_paths.is_empty() {
            return Err("Windows display recovery topology has no target paths".to_owned());
        }
        let paths = topology
            .windows_target_paths
            .iter()
            .map(|record| {
                serde_json::from_str::<WindowsPathRecord>(record)
                    .map_err(|_| "Windows display recovery path is malformed".to_owned())
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut targets = BTreeSet::new();
        let mut sources = BTreeMap::new();
        for path in &paths {
            let source = path
                .source_mode
                .ok_or_else(|| "Windows display recovery source mode is missing".to_owned())?;
            if source.width == 0
                || source.height == 0
                || path.refresh_rate.denominator == 0
                || path.path_flags & 1 == 0
                || !targets.insert((path.target_adapter, path.target_id))
            {
                return Err("Windows display recovery path is invalid".to_owned());
            }
            let source_key = (path.source_adapter, path.source_id);
            if sources
                .insert(source_key, source)
                .is_some_and(|existing| existing != source)
            {
                return Err("Windows display recovery clone source is inconsistent".to_owned());
            }
        }
        Ok(Self { paths })
    }

    pub(super) fn isolated_for(&self, identity: WindowsPathIdentity) -> Result<Self, String> {
        let paths = self
            .paths
            .iter()
            .filter(|path| {
                path.target_adapter == identity.adapter && path.target_id == identity.target_id
            })
            .cloned()
            .collect::<Vec<_>>();
        if paths.len() != 1 {
            return Err("Windows could not select exactly one IDD target path".to_owned());
        }
        Ok(Self { paths })
    }

    pub(super) fn physical_without(&self, identity: WindowsPathIdentity) -> Result<Self, String> {
        let matching = self
            .paths
            .iter()
            .filter(|path| path_identity(path) == identity)
            .count();
        let paths = self
            .paths
            .iter()
            .filter(|path| path_identity(path) != identity)
            .cloned()
            .collect::<Vec<_>>();
        if matching != 1 || paths.is_empty() {
            return Err(
                "Windows hotplug snapshot could not separate one IDD path from physical paths"
                    .to_owned(),
            );
        }
        Ok(Self { paths })
    }

    #[cfg(windows)]
    pub(super) fn new_path_since(&self, before: &Self) -> Result<WindowsPathIdentity, String> {
        let previous = before
            .paths
            .iter()
            .map(path_identity)
            .collect::<BTreeSet<_>>();
        let added = self
            .paths
            .iter()
            .map(path_identity)
            .filter(|identity| !previous.contains(identity))
            .collect::<Vec<_>>();
        match added.as_slice() {
            [identity] => Ok(*identity),
            _ => Err("Windows could not identify exactly one newly arrived IDD path".to_owned()),
        }
    }

    pub(super) fn matches_exact_isolation(
        &self,
        identity: WindowsPathIdentity,
        observed: &Self,
    ) -> bool {
        self.paths.len() == 1
            && self
                .paths
                .iter()
                .all(|path| path_identity(path) == identity)
            && self == observed
    }
}

fn path_identity(path: &WindowsPathRecord) -> WindowsPathIdentity {
    WindowsPathIdentity {
        adapter: path.target_adapter,
        target_id: path.target_id,
    }
}

fn display_id(adapter: AdapterLuid, target_id: u32) -> String {
    format!("{}:{:08x}:{target_id}", adapter.high_part, adapter.low_part)
}

#[cfg(test)]
#[path = "display_topology_tests.rs"]
mod tests;
