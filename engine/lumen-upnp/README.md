# lumen-upnp

`lumen-upnp` is a small synchronous Rust library for route-aware UPnP Internet Gateway Device discovery and fixed port mapping.

Unlike discovery APIs that always send SSDP to the multicast group through an unspecified socket, callers provide the local address and gateway endpoint selected by their routing policy. This makes startup recovery deterministic on hosts where VPN or point-to-point interfaces coexist with the LAN interface.

```rust,no_run
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;
use lumen_upnp::{discover_gateway, DiscoveryOptions, PortMappingProtocol};

let local_ip = IpAddr::V4(Ipv4Addr::new(192, 168, 0, 51));
let gateway = discover_gateway(DiscoveryOptions {
    bind_address: SocketAddr::new(local_ip, 0),
    discovery_address: "192.168.0.1:1900".parse()?,
    timeout: Duration::from_secs(2),
})?;

gateway.add_port(
    PortMappingProtocol::Tcp,
    48_990,
    SocketAddr::new(local_ip, 48_990),
    600,
    "HTTPS control",
)?;
# Ok::<(), Box<dyn std::error::Error>>(())
```

The crate intentionally owns only SSDP discovery, IGD service resolution, and the `AddPortMapping` / `DeletePortMapping` SOAP actions. Route and interface selection remain explicit caller policy.

Licensed under MIT, matching the repository root license.
