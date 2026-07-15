mod catalog;
mod document;
mod ffi;
mod model;

pub use catalog::ApplicationCatalog;
pub(crate) use document::random_uuid;
pub use model::{
    ApplicationCommandPlan, ApplicationDescriptor, ApplicationLaunchPlan, CatalogError,
};

#[cfg(test)]
mod tests;
