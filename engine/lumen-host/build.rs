fn main() {
    println!("cargo:rerun-if-changed=ui/windows-app.slint");
    println!("cargo:rerun-if-changed=translations");
    println!("cargo:rerun-if-changed=../../icon.svg");
    println!("cargo:rerun-if-changed=../../src_assets/common/assets/icons/ui");
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        let configuration =
            slint_build::CompilerConfiguration::new().with_bundled_translations("translations");
        slint_build::compile_with_config("ui/windows-app.slint", configuration)
            .expect("compile Windows Lumen UI");
    }
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
