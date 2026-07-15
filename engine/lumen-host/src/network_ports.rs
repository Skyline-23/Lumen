use crate::HostArguments;

pub(crate) const CONTROL_HTTPS_OFFSET: u16 = 1;
pub(crate) const VIDEO_UDP_OFFSET: u16 = 9;
pub(crate) const NATIVE_QUIC_OFFSET: u16 = 21;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct HostPorts {
    pub(crate) control_https: u16,
    pub(crate) native_media_udp: u16,
    pub(crate) native_session_quic: u16,
}

impl HostPorts {
    pub(crate) fn from_arguments(arguments: &HostArguments) -> Result<Self, String> {
        let base = arguments
            .get("port")
            .and_then(|value| value.parse::<u16>().ok())
            .ok_or_else(|| "host base port is invalid".to_owned())?;
        Ok(Self {
            control_https: add(base, CONTROL_HTTPS_OFFSET, "control HTTPS")?,
            native_media_udp: add(base, VIDEO_UDP_OFFSET, "native media UDP")?,
            native_session_quic: add(base, NATIVE_QUIC_OFFSET, "native session QUIC")?,
        })
    }
}

fn add(base: u16, offset: u16, name: &str) -> Result<u16, String> {
    base.checked_add(offset)
        .ok_or_else(|| format!("{name} port overflowed"))
}
