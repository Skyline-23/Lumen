use std::fs;

use serde_json::Value;

use super::*;

fn write_catalog(path: &std::path::Path) {
    fs::write(
        path,
        br#"{"env":{},"apps":[{"name":"Desktop","image-path":"desktop.png"}]}"#,
    )
    .unwrap();
}

#[test]
fn catalog_assigns_ids_and_persists_validated_updates() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("apps.json");
    write_catalog(&path);
    let catalog = ApplicationCatalog::open(path.clone()).unwrap();
    let initial: Value = serde_json::from_slice(&catalog.json().unwrap()).unwrap();
    let desktop_id = initial["apps"][0]["uuid"].as_str().unwrap().to_owned();
    assert!(!desktop_id.is_empty());

    catalog
        .upsert(r#"{"name":"Editor","cmd":"open -a TextEdit"}"#)
        .unwrap();
    let updated: Value = serde_json::from_slice(&catalog.json().unwrap()).unwrap();
    assert_eq!(updated["apps"].as_array().unwrap().len(), 2);
    assert_eq!(updated["apps"][1]["name"], "Editor");
}

#[test]
fn catalog_initializes_a_missing_document() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("nested").join("apps.json");
    let catalog = ApplicationCatalog::open(path.clone()).unwrap();
    let document: Value = serde_json::from_slice(&catalog.json().unwrap()).unwrap();
    assert_eq!(document["env"], serde_json::json!({}));
    assert_eq!(document["apps"], serde_json::json!([]));
    assert!(path.is_file());
}

#[test]
fn catalog_reorders_and_deletes_by_stable_id() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("apps.json");
    fs::write(
        &path,
        br#"{"apps":[{"uuid":"desktop","name":"Desktop"},{"uuid":"editor","name":"Editor"}]}"#,
    )
    .unwrap();
    let catalog = ApplicationCatalog::open(path).unwrap();
    catalog.reorder(r#"["editor","desktop"]"#).unwrap();
    catalog.delete("desktop").unwrap();
    let updated: Value = serde_json::from_slice(&catalog.json().unwrap()).unwrap();
    assert_eq!(updated["apps"].as_array().unwrap().len(), 1);
    assert_eq!(updated["apps"][0]["uuid"], "editor");
}

#[test]
fn builds_one_strict_typed_application_launch_plan() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("apps.json");
    fs::write(
        &path,
        br#"{
          "env":{"LUMEN_ROOT":"C:\\Games"},
          "apps":[{
            "uuid":"editor",
            "name":"Editor",
            "cmd":"editor.exe --remote",
            "working-dir":"$(LUMEN_ROOT)\\Editor",
            "output":"editor.log",
            "image-path":"editor.png",
            "prep-cmd":[{"do":"prepare.exe","undo":"restore.exe","elevated":true}],
            "state-cmd":[{"do":"resume.exe","undo":"pause.exe"}],
            "detached":["overlay.exe"],
            "exclude-global-prep-cmd":true,
            "exclude-global-state-cmd":true,
            "elevated":false,
            "auto-detach":false,
            "wait-all":false,
            "exit-timeout":9,
            "virtual-display":true,
            "scale-factor":150,
            "use-app-identity":true,
            "per-client-app-identity":true,
            "terminate-on-pause":true,
            "gamepad":"ds4"
          }]
        }"#,
    )
    .unwrap();
    let catalog = ApplicationCatalog::open(path).unwrap();
    let descriptor = catalog.applications().unwrap().remove(0);
    let plan = catalog.launch_plan(descriptor.id).unwrap();
    assert_eq!(plan.uuid, "editor");
    assert_eq!(plan.command, "editor.exe --remote");
    assert_eq!(plan.working_directory, "$(LUMEN_ROOT)\\Editor");
    assert_eq!(plan.environment["LUMEN_ROOT"], "C:\\Games");
    assert_eq!(
        plan.prep_commands,
        vec![ApplicationCommandPlan {
            run: "prepare.exe".to_owned(),
            undo: "restore.exe".to_owned(),
            elevated: true,
        }]
    );
    assert_eq!(plan.state_commands[0].run, "resume.exe");
    assert_eq!(plan.detached_commands, ["overlay.exe"]);
    assert!(plan.exclude_global_prep_commands);
    assert!(plan.exclude_global_state_commands);
    assert!(!plan.auto_detach);
    assert!(!plan.wait_all);
    assert_eq!(plan.exit_timeout_seconds, 9);
    assert!(plan.virtual_display);
    assert_eq!(plan.scale_percent, 150);
    assert!(plan.use_app_identity);
    assert!(plan.per_client_app_identity);
    assert!(plan.terminate_on_pause);
    assert_eq!(plan.gamepad, "ds4");
}

#[test]
fn rejects_corrupt_launch_only_fields_without_hiding_the_catalog_entry() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("apps.json");
    fs::write(
        &path,
        br#"{"env":{},"apps":[{"uuid":"bad","name":"Bad","exit-timeout":"five"}]}"#,
    )
    .unwrap();
    let catalog = ApplicationCatalog::open(path).unwrap();
    let descriptor = catalog.applications().unwrap().remove(0);
    assert_eq!(
        catalog.launch_plan(descriptor.id),
        Err(CatalogError::Corrupt)
    );
}
