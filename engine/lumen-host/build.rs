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
}
