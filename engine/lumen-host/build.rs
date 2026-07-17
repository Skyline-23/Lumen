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
        let opus_archive = std::env::var_os("LUMEN_OPUS_ARCHIVE")
            .map(std::path::PathBuf::from)
            .or_else(|| {
                [
                    "/opt/homebrew/opt/opus/lib/libopus.a",
                    "/usr/local/opt/opus/lib/libopus.a",
                ]
                .into_iter()
                .map(std::path::PathBuf::from)
                .find(|path| path.is_file())
            })
            .expect("macOS Lumen host requires a static Opus archive");
        println!(
            "cargo:rustc-link-search=native={}",
            opus_archive
                .parent()
                .expect("Opus archive parent")
                .display()
        );
        println!("cargo:rustc-link-lib=static=opus");
        let info_plist = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap())
            .join("resources/macos-worker-info.plist");
        println!(
            "cargo:rustc-link-arg-bin=lumen-host=-Wl,-sectcreate,__TEXT,__info_plist,{}",
            info_plist.display()
        );
        println!("cargo:rerun-if-changed={}", info_plist.display());
    }
}
