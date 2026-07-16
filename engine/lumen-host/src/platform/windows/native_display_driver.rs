use std::ffi::c_void;
use std::mem::size_of;
use std::ptr::{null, null_mut};
use std::thread;
use std::time::Duration;

use windows_sys::core::GUID;
use windows_sys::Win32::Devices::DeviceAndDriverInstallation::{
    SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInterfaces, SetupDiGetClassDevsW,
    SetupDiGetDeviceInterfaceDetailW, DIGCF_DEVICEINTERFACE, DIGCF_PRESENT, HDEVINFO,
    SP_DEVICE_INTERFACE_DATA, SP_DEVICE_INTERFACE_DETAIL_DATA_W,
};
use windows_sys::Win32::Foundation::{
    CloseHandle, DuplicateHandle, GetLastError, DUPLICATE_SAME_ACCESS, GENERIC_READ, GENERIC_WRITE,
    HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::Threading::GetCurrentProcess;
use windows_sys::Win32::System::IO::DeviceIoControl;

use super::driver_abi::{
    CoreRequest, CoreResponse, FrameRecord, ABI_FRAME_SIZE, DEVICE_INTERFACE_GUID,
    IOCTL_ADOPT_MONITOR, IOCTL_CREATE_MONITOR, IOCTL_DEQUEUE_FRAME, IOCTL_QUERY_BACKEND_CAPABILITY,
    IOCTL_QUERY_CAPABILITIES, IOCTL_QUERY_HEALTH, IOCTL_QUERY_MONITOR, IOCTL_REMOVE_MONITOR,
    IOCTL_START_ENCODER, IOCTL_STOP_ENCODER, OPERATION_ADOPT_MONITOR, OPERATION_CREATE_MONITOR,
    OPERATION_DEQUEUE_FRAME, OPERATION_QUERY_BACKEND_CAPABILITY, OPERATION_QUERY_CAPABILITIES,
    OPERATION_QUERY_HEALTH, OPERATION_QUERY_MONITOR, OPERATION_REMOVE_MONITOR,
    OPERATION_START_ENCODER, OPERATION_STOP_ENCODER, STATE_MONITOR_ACTIVE, STATE_MONITOR_ORPHANED,
    STATUS_NOT_READY, STATUS_OK,
};

const DRIVER_INTERFACE_GUID: GUID = GUID::from_u128(DEVICE_INTERFACE_GUID);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum MonitorState {
    Missing,
    Owned(u64),
    Orphaned(u64),
}

pub(super) struct DriverHandle {
    raw: usize,
    generation: u64,
    next_request_id: u64,
}

impl DriverHandle {
    pub(super) fn open() -> Result<Self, String> {
        let raw = open_with_retry()?;
        let mut driver = Self {
            raw: raw as usize,
            generation: 0,
            next_request_id: 1,
        };
        let capabilities = driver.request(
            IOCTL_QUERY_CAPABILITIES,
            OPERATION_QUERY_CAPABILITIES,
            [0; 5],
        )?;
        if capabilities.status != STATUS_OK || capabilities.values[0] == 0 {
            return Err("Windows driver capability query failed".to_owned());
        }
        driver.generation = capabilities.generation;
        let health = driver.request(IOCTL_QUERY_HEALTH, OPERATION_QUERY_HEALTH, [0; 5])?;
        if health.status != STATUS_OK || health.generation != driver.generation {
            return Err("Windows driver health query failed".to_owned());
        }
        Ok(driver)
    }

    pub(super) fn create_monitor(
        &self,
        monitor_id: u64,
        width: u32,
        height: u32,
        refresh_millihertz: u32,
    ) -> Result<(), String> {
        let response = self.request(
            IOCTL_CREATE_MONITOR,
            OPERATION_CREATE_MONITOR,
            [
                monitor_id,
                (u64::from(width) << 32) | u64::from(height),
                u64::from(refresh_millihertz),
                0,
                0,
            ],
        )?;
        require_ok(response, "create monitor")
    }

    pub(super) fn query_monitor(&self) -> Result<MonitorState, String> {
        let response = self.request(IOCTL_QUERY_MONITOR, OPERATION_QUERY_MONITOR, [0; 5])?;
        require_ok(response, "query monitor")?;
        let monitor_id = response.values[0];
        let flags = u32::try_from(response.values[1])
            .map_err(|_| "Windows driver monitor flags overflowed".to_owned())?;
        if flags & STATE_MONITOR_ACTIVE == 0 {
            return Ok(MonitorState::Missing);
        }
        if monitor_id == 0 {
            return Err("Windows driver reported an active monitor without identity".to_owned());
        }
        if flags & STATE_MONITOR_ORPHANED != 0 {
            Ok(MonitorState::Orphaned(monitor_id))
        } else {
            Ok(MonitorState::Owned(monitor_id))
        }
    }

    pub(super) fn adopt_monitor(&self, monitor_id: u64) -> Result<(), String> {
        let response = self.request(
            IOCTL_ADOPT_MONITOR,
            OPERATION_ADOPT_MONITOR,
            [monitor_id, 0, 0, 0, 0],
        )?;
        require_ok(response, "adopt monitor")
    }

    pub(super) fn remove_monitor(&self, monitor_id: u64) -> Result<(), String> {
        let response = self.request(
            IOCTL_REMOVE_MONITOR,
            OPERATION_REMOVE_MONITOR,
            [monitor_id, 0, 0, 0, 0],
        )?;
        require_ok(response, "remove monitor")
    }

    pub(super) fn duplicate(&self) -> Result<Self, String> {
        let process = unsafe { GetCurrentProcess() };
        let mut duplicated = std::ptr::null_mut();
        let succeeded = unsafe {
            DuplicateHandle(
                process,
                self.raw(),
                process,
                &mut duplicated,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            )
        };
        if succeeded == 0 || duplicated.is_null() {
            return Err(format!(
                "Windows driver handle duplication failed: {}",
                unsafe { GetLastError() }
            ));
        }
        Ok(Self {
            raw: duplicated as usize,
            generation: self.generation,
            next_request_id: 1,
        })
    }

    pub(super) fn render_adapter_luid(&self) -> Result<u64, String> {
        let response = self.request(
            IOCTL_QUERY_BACKEND_CAPABILITY,
            OPERATION_QUERY_BACKEND_CAPABILITY,
            [0; 5],
        )?;
        require_ok(response, "query render adapter")?;
        if response.values[0] == 0 {
            return Err("Windows driver returned an empty render adapter LUID".to_owned());
        }
        Ok(response.values[0])
    }

    pub(super) fn start_frame_delivery(&self) -> Result<(), String> {
        require_ok(
            self.request(IOCTL_START_ENCODER, OPERATION_START_ENCODER, [0; 5])?,
            "start frame delivery",
        )
    }

    pub(super) fn stop_frame_delivery(&self) -> Result<(), String> {
        let response = self.request(IOCTL_STOP_ENCODER, OPERATION_STOP_ENCODER, [0; 5])?;
        if matches!(response.status, STATUS_OK | STATUS_NOT_READY) {
            Ok(())
        } else {
            Err(format!(
                "Windows driver stop frame delivery returned status {}",
                response.status
            ))
        }
    }

    pub(super) fn dequeue_frame(&mut self) -> Result<FrameRecord, String> {
        let request_id = self.next_request_id;
        self.next_request_id = self.next_request_id.checked_add(1).unwrap_or(1);
        let mut request = CoreRequest::new(OPERATION_DEQUEUE_FRAME, self.generation);
        request.request_id = request_id;
        request.arguments[0] = u64::from(ABI_FRAME_SIZE);
        let mut frame = FrameRecord::default();
        let mut returned = 0;
        let succeeded = unsafe {
            DeviceIoControl(
                self.raw(),
                IOCTL_DEQUEUE_FRAME,
                (&raw const request).cast::<c_void>(),
                u32::try_from(size_of::<CoreRequest>())
                    .map_err(|_| "Windows frame request size overflowed".to_owned())?,
                (&raw mut frame).cast::<c_void>(),
                ABI_FRAME_SIZE,
                &mut returned,
                null_mut(),
            )
        };
        if succeeded == 0 {
            return Err(format!("Windows driver frame dequeue failed: {}", unsafe {
                GetLastError()
            }));
        }
        if returned != ABI_FRAME_SIZE
            || frame.header.magic != super::driver_abi::ABI_MAGIC
            || frame.header.major != super::driver_abi::ABI_MAJOR
            || frame.header.minor > super::driver_abi::ABI_MINOR
            || frame.header.structure_size != ABI_FRAME_SIZE
            || frame.header.operation != OPERATION_DEQUEUE_FRAME
            || frame.generation != self.generation
            || frame.request_id != request_id
            || frame.monitor_id == 0
            || frame.frame_id == 0
            || frame.width == 0
            || frame.height == 0
            || frame.surface_revision == 0
        {
            return Err("Windows driver returned an invalid shared frame record".to_owned());
        }
        Ok(frame)
    }

    fn request(
        &self,
        ioctl: u32,
        operation: u32,
        arguments: [u64; 5],
    ) -> Result<CoreResponse, String> {
        let mut request = CoreRequest::new(operation, self.generation);
        request.arguments = arguments;
        let mut response = CoreResponse::default();
        let mut returned = 0;
        let input_size = u32::try_from(size_of::<CoreRequest>())
            .map_err(|_| "Windows driver request size overflowed".to_owned())?;
        let output_size = u32::try_from(size_of::<CoreResponse>())
            .map_err(|_| "Windows driver response size overflowed".to_owned())?;
        // SAFETY: Category 8 (FFI boundary). Both fixed-layout ABI buffers remain live for the synchronous call, and their exact sizes are passed to the driver.
        let succeeded = unsafe {
            DeviceIoControl(
                self.raw(),
                ioctl,
                (&raw const request).cast::<c_void>(),
                input_size,
                (&raw mut response).cast::<c_void>(),
                output_size,
                &mut returned,
                null_mut(),
            )
        };
        if succeeded == 0 {
            return Err(format!(
                "Windows driver operation {operation} failed: {}",
                unsafe { GetLastError() }
            ));
        }
        if returned != output_size {
            return Err(format!(
                "Windows driver operation {operation} returned {returned} bytes instead of {output_size}"
            ));
        }
        response.validate(operation)
    }

    fn raw(&self) -> HANDLE {
        self.raw as HANDLE
    }
}

pub(super) fn shared_frame_name(monitor_id: u64, surface_revision: u32) -> String {
    format!("Global\\LumenFrame-{monitor_id:016X}-{surface_revision:08X}")
}

impl Drop for DriverHandle {
    fn drop(&mut self) {
        // SAFETY: Category 8 (FFI boundary). The handle is uniquely owned and closed exactly once.
        unsafe { CloseHandle(self.raw()) };
    }
}

fn require_ok(response: CoreResponse, action: &str) -> Result<(), String> {
    if response.status == STATUS_OK {
        Ok(())
    } else {
        Err(format!(
            "Windows driver {action} returned status {}",
            response.status
        ))
    }
}

fn open_with_retry() -> Result<HANDLE, String> {
    for delay in [0, 40, 80, 160, 320, 640] {
        if delay != 0 {
            thread::sleep(Duration::from_millis(delay));
        }
        if let Some(handle) = open_driver_once() {
            return Ok(handle);
        }
    }
    Err(format!(
        "Windows first-party display driver is unavailable: {}",
        unsafe { GetLastError() }
    ))
}

struct DeviceInfoSet(HDEVINFO);

impl DeviceInfoSet {
    fn open() -> Option<Self> {
        // SAFETY: Category 8 (FFI boundary). The constant interface GUID and null optional pointers satisfy SetupAPI's contract.
        let value = unsafe {
            SetupDiGetClassDevsW(
                &DRIVER_INTERFACE_GUID,
                null(),
                null_mut(),
                DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
            )
        };
        (value != INVALID_HANDLE_VALUE as isize).then_some(Self(value))
    }
}

impl Drop for DeviceInfoSet {
    fn drop(&mut self) {
        // SAFETY: Category 8 (FFI boundary). This wrapper uniquely owns the SetupAPI set.
        unsafe { SetupDiDestroyDeviceInfoList(self.0) };
    }
}

fn open_driver_once() -> Option<HANDLE> {
    let devices = DeviceInfoSet::open()?;
    let mut interface = SP_DEVICE_INTERFACE_DATA {
        cbSize: size_of::<SP_DEVICE_INTERFACE_DATA>() as u32,
        ..Default::default()
    };
    let mut index = 0;
    // SAFETY: Category 8 (FFI boundary). The device set and writable interface record remain live throughout enumeration.
    while unsafe {
        SetupDiEnumDeviceInterfaces(
            devices.0,
            null(),
            &DRIVER_INTERFACE_GUID,
            index,
            &mut interface,
        )
    } != 0
    {
        index += 1;
        let mut required_size = 0;
        // SAFETY: Category 8 (FFI boundary). A null detail buffer is the documented size-query form.
        unsafe {
            SetupDiGetDeviceInterfaceDetailW(
                devices.0,
                &interface,
                null_mut(),
                0,
                &mut required_size,
                null_mut(),
            )
        };
        if required_size < size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32 {
            continue;
        }
        let mut storage = vec![0_u8; required_size as usize];
        let detail = storage
            .as_mut_ptr()
            .cast::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>();
        // SAFETY: Category 8 (FFI boundary). The byte allocation has the driver-reported size and is aligned sufficiently for the detail header used here.
        unsafe { (*detail).cbSize = size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32 };
        // SAFETY: Category 8 (FFI boundary). SetupAPI writes at most required_size bytes into the live allocation.
        let resolved = unsafe {
            SetupDiGetDeviceInterfaceDetailW(
                devices.0,
                &interface,
                detail,
                required_size,
                &mut required_size,
                null_mut(),
            )
        };
        if resolved == 0 {
            continue;
        }
        // SAFETY: Category 8 (FFI boundary). DevicePath begins a null-terminated UTF-16 string inside the retained detail allocation.
        let path = unsafe { std::ptr::addr_of!((*detail).DevicePath).cast::<u16>() };
        // SAFETY: Category 8 (FFI boundary). The path is live and null terminated; successful ownership transfers into DriverHandle.
        let handle = unsafe {
            CreateFileW(
                path,
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                null(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                null_mut(),
            )
        };
        if !handle.is_null() && handle != INVALID_HANDLE_VALUE {
            return Some(handle);
        }
    }
    None
}
