fn main() {
    if std::env::var_os("CARGO_CFG_TARGET_OS").as_deref() == Some(std::ffi::OsStr::new("macos")) {
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=framework=CoreMedia");
        let info_plist = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap())
            .join("resources/macos-worker-info.plist");
        println!(
            "cargo:rustc-link-arg-bin=lumen-host=-Wl,-sectcreate,__TEXT,__info_plist,{}",
            info_plist.display()
        );
        println!("cargo:rerun-if-changed={}", info_plist.display());
    }
}
