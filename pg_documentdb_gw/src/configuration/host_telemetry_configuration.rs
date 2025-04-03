use serde::{Deserialize, Serialize};
use std::fs;
use std::sync::OnceLock;

#[derive(Debug, Deserialize, Serialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct Dimensions {
    pub customer_subscription_id: Option<String>,
    pub environment: Option<String>,
    pub region: Option<String>,
    pub server_location: Option<String>,
    pub logical_server_name: Option<String>,
    pub instance_id: Option<String>,
    pub original_primary_server_name: Option<String>,
    pub server_type: Option<String>,
    pub server_version: Option<String>,
    pub server_group_name: Option<String>,
    pub replica_role: Option<String>,
    pub virtual_machine_name: Option<String>,
    pub server_os_type: Option<String>,
    pub resource_id: Option<String>,
    pub server_group_resource_id: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct HostTelemetryConfiguration {
    pub dims: Dimensions,
}

// Global static instance for configuration
static CONFIG: OnceLock<HostTelemetryConfiguration> = OnceLock::new();

impl HostTelemetryConfiguration {
    pub fn load_from_file(
        path: &str,
    ) -> Result<HostTelemetryConfiguration, Box<dyn std::error::Error>> {
        match fs::read_to_string(path) {
            Ok(data) => match serde_json::from_str(&data) {
                Ok(config) => Ok(config),
                Err(_) => {
                    log::warn!("Failed to deserialize config, using default.");
                    Ok(HostTelemetryConfiguration::default())
                }
            },
            Err(_) => {
                log::warn!("Failed to read config file, using default.");
                Ok(HostTelemetryConfiguration::default())
            }
        }
    }

    pub fn get() -> &'static HostTelemetryConfiguration {
        CONFIG
            .get()
            .expect("Config not initialized. Call load_from_file() first.")
    }
}
