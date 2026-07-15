fn main() {
    println!("cargo:rerun-if-changed=ui/windows-app.slint");
    println!("cargo:rerun-if-changed=../../icon.svg");
    println!("cargo:rerun-if-changed=../../src_assets/common/assets/icons/ui");
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        slint_build::compile("ui/windows-app.slint").expect("compile Windows Lumen UI");
    }
}
