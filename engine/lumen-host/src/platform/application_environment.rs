use std::collections::BTreeMap;

use lumen_engine::ApplicationLaunchPlan;

use crate::PlatformApplicationPlan;

pub(crate) fn application_environment(
    application: &ApplicationLaunchPlan,
    plan: &PlatformApplicationPlan,
) -> Result<BTreeMap<String, String>, String> {
    let mut environment = std::env::vars().collect::<BTreeMap<_, _>>();
    for (key, value) in &application.environment {
        let expanded = expand(value, &environment)?;
        environment.insert(key.clone(), expanded);
    }
    environment.insert("SHADOW_APP_ID".to_owned(), application.id.to_string());
    environment.insert("SHADOW_APP_NAME".to_owned(), application.name.clone());
    environment.insert("SHADOW_APP_UUID".to_owned(), application.uuid.clone());
    environment.insert("SHADOW_APP_STATUS".to_owned(), "RUNNING".to_owned());
    environment.insert("SHADOW_CLIENT_WIDTH".to_owned(), plan.width.to_string());
    environment.insert("SHADOW_CLIENT_HEIGHT".to_owned(), plan.height.to_string());
    environment.insert(
        "SHADOW_CLIENT_FPS".to_owned(),
        plan.frames_per_second.to_string(),
    );
    environment.insert(
        "SHADOW_CLIENT_SCALE_FACTOR".to_owned(),
        application.scale_percent.to_string(),
    );
    environment.insert(
        "SHADOW_CLIENT_HDR".to_owned(),
        (plan.session_offer.requested_transport != 0).to_string(),
    );
    Ok(environment)
}

pub(crate) fn expand(
    value: &str,
    environment: &BTreeMap<String, String>,
) -> Result<String, String> {
    let mut expanded = String::with_capacity(value.len());
    let mut remaining = value;
    while let Some(offset) = remaining.find('$') {
        expanded.push_str(&remaining[..offset]);
        remaining = &remaining[offset + 1..];
        if let Some(rest) = remaining.strip_prefix('$') {
            expanded.push('$');
            remaining = rest;
            continue;
        }
        let Some(variable) = remaining.strip_prefix('(') else {
            return Err("Application value contains an invalid environment reference".to_owned());
        };
        let Some(end) = variable.find(')') else {
            return Err(
                "Application value contains an unterminated environment reference".to_owned(),
            );
        };
        let key = &variable[..end];
        let replacement = environment
            .get(key)
            .ok_or_else(|| format!("Application environment variable {key} is not defined"))?;
        expanded.push_str(replacement);
        remaining = &variable[end + 1..];
    }
    expanded.push_str(remaining);
    Ok(expanded)
}
