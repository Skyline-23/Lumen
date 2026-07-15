use std::fs;
use std::io::Write;
use std::path::PathBuf;

use serde_json::Value;

use super::document::{
    application_descriptor, application_launch_plan, applications_mut, entry_id,
    normalize_application, normalize_document, normalized_id,
};
use super::model::{ApplicationDescriptor, ApplicationLaunchPlan, CatalogError};

#[derive(Debug)]
pub struct ApplicationCatalog {
    file_path: PathBuf,
}

impl ApplicationCatalog {
    pub fn open(file_path: PathBuf) -> Result<Self, CatalogError> {
        if file_path.as_os_str().is_empty() || file_path.file_name().is_none() {
            return Err(CatalogError::InvalidArgument);
        }
        let should_initialize = !file_path.exists();
        let catalog = Self { file_path };
        let mut document = catalog.read_document()?;
        if should_initialize || normalize_document(&mut document)? {
            catalog.write_document(&document)?;
        }
        Ok(catalog)
    }

    pub fn json(&self) -> Result<Vec<u8>, CatalogError> {
        let document = self.read_document()?;
        serde_json::to_vec_pretty(&document).map_err(|_| CatalogError::Corrupt)
    }

    pub fn applications(&self) -> Result<Vec<ApplicationDescriptor>, CatalogError> {
        let mut document = self.read_document()?;
        normalize_document(&mut document)?;
        applications_mut(&mut document)?
            .iter()
            .map(application_descriptor)
            .collect()
    }

    pub fn launch_plan(&self, application_id: u32) -> Result<ApplicationLaunchPlan, CatalogError> {
        if application_id == 0 {
            return Err(CatalogError::InvalidArgument);
        }
        let mut document = self.read_document()?;
        normalize_document(&mut document)?;
        let environment = super::document::document_environment(&document)?;
        let application = applications_mut(&mut document)?
            .iter()
            .find(|application| {
                application
                    .get("id")
                    .and_then(Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
                    == Some(application_id)
            })
            .ok_or(CatalogError::InvalidArgument)?;
        application_launch_plan(application, environment)
    }

    pub fn upsert(&self, application_json: &str) -> Result<(), CatalogError> {
        let mut application: Value =
            serde_json::from_str(application_json).map_err(|_| CatalogError::InvalidArgument)?;
        normalize_application(&mut application)?;
        let application_id = entry_id(&application)?.to_owned();
        let mut document = self.read_document()?;
        normalize_document(&mut document)?;
        let applications = applications_mut(&mut document)?;
        if let Some(existing) = applications
            .iter_mut()
            .find(|entry| entry_id(entry).ok() == Some(application_id.as_str()))
        {
            *existing = application;
        } else {
            applications.push(application);
        }
        self.write_document(&document)
    }

    pub fn delete(&self, application_id: &str) -> Result<(), CatalogError> {
        let target_id = normalized_id(application_id)?;
        let mut document = self.read_document()?;
        normalize_document(&mut document)?;
        applications_mut(&mut document)?
            .retain(|entry| entry_id(entry).ok() != Some(target_id.as_str()));
        self.write_document(&document)
    }

    pub fn reorder(&self, application_ids_json: &str) -> Result<(), CatalogError> {
        let order: Vec<String> = serde_json::from_str(application_ids_json)
            .map_err(|_| CatalogError::InvalidArgument)?;
        let order = order
            .into_iter()
            .map(|value| normalized_id(&value))
            .collect::<Result<Vec<_>, _>>()?;
        let mut document = self.read_document()?;
        normalize_document(&mut document)?;
        let applications = applications_mut(&mut document)?;
        let mut remaining = std::mem::take(applications);
        let mut reordered = Vec::with_capacity(remaining.len());
        for target_id in order {
            if let Some(index) = remaining
                .iter()
                .position(|entry| entry_id(entry).ok() == Some(target_id.as_str()))
            {
                reordered.push(remaining.remove(index));
            }
        }
        reordered.append(&mut remaining);
        *applications = reordered;
        self.write_document(&document)
    }

    fn read_document(&self) -> Result<Value, CatalogError> {
        let data = fs::read(&self.file_path).map_err(|_| CatalogError::Storage);
        let data = match data {
            Ok(data) => data,
            Err(CatalogError::Storage) if !self.file_path.exists() => {
                return Ok(super::document::default_document());
            }
            Err(error) => return Err(error),
        };
        serde_json::from_slice(&data).map_err(|_| CatalogError::Corrupt)
    }

    fn write_document(&self, document: &Value) -> Result<(), CatalogError> {
        let parent = self
            .file_path
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .ok_or(CatalogError::InvalidArgument)?;
        fs::create_dir_all(parent).map_err(|_| CatalogError::Storage)?;
        let serialized = serde_json::to_vec_pretty(document).map_err(|_| CatalogError::Storage)?;
        let mut temporary_file = tempfile::Builder::new()
            .prefix(".applications.")
            .tempfile_in(parent)
            .map_err(|_| CatalogError::Storage)?;
        temporary_file
            .write_all(&serialized)
            .and_then(|_| temporary_file.as_file().sync_all())
            .map_err(|_| CatalogError::Storage)?;
        temporary_file
            .persist(&self.file_path)
            .map_err(|_| CatalogError::Storage)?;
        Ok(())
    }
}
