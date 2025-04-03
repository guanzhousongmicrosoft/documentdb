use std::path::Path;

use serde::Deserialize;
use tokio::fs::File;

use crate::error::{DocumentDBError, Result};

// Configurations which are populated statically on process start
#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct SetupConfiguration {
    pub node_host_name: String,
    pub region_name: String,
    pub blocked_role_prefixes: Vec<String>,

    // Mongo listener configuration
    #[serde(default)]
    pub use_local_host: bool,
    pub mongo_listen_port: Option<u16>,

    // Health probe listener
    pub http_listen_port: Option<u16>,

    // Postgres configuration
    pub postgres_system_user: Option<String>,
    pub postgres_host_name: Option<String>,
    pub postgres_port: Option<u16>,
    pub postgres_database: Option<String>,

    #[serde(default)]
    pub allow_transaction_snapshot: bool,
    pub transaction_timeout_secs: Option<u64>,
    pub cursor_timeout_secs: Option<u64>,

    pub enforce_ssl_tcp: bool,
    pub certificate_options: Option<CertificateOptions>,

    pub logging_options: Option<LoggingOptions>,

    pub dynamic_configuration_file: String,
    pub dynamic_configuration_refresh_interval_secs: Option<u32>,

    pub metrics_configuration_file: Option<String>,

    pub postgres_command_timeout_secs: Option<u64>,
}

#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct CertificateOptions {
    pub cert_type: String,
    pub file_path: String,
    pub key_file_path: String,
    pub ca_path: Option<String>,
}

#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct LoggingOptions {
    pub types: String,
    pub setup_max_retries: Option<u32>,
    pub setup_retry_delay_seconds: Option<u32>,
    pub fluent_socket: Option<String>,
    pub warmpath_logging_mode: Option<String>,
}

impl SetupConfiguration {
    pub async fn new(config_path: &Path) -> Result<Self> {
        let config_file = File::open(config_path).await?;
        serde_json::from_reader(config_file.into_std().await).map_err(|e| {
            DocumentDBError::internal_error(format!("Failed to parse configuration file: {}", e))
        })
    }
}

#[cfg(test)]
impl SetupConfiguration {
    pub fn new_for_test() -> Self {
        SetupConfiguration {
            node_host_name: "localhost".to_string(),
            region_name: "narnia".to_string(),
            postgres_system_user: None,
            blocked_role_prefixes: Vec::new(),
            ..Default::default()
        }
    }
}
