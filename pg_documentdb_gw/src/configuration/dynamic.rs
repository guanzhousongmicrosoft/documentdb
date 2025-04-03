use std::{collections::HashMap, fmt::Debug};

use bson::RawBson;
use serde::Deserialize;

use crate::error::{DocumentDBError, Result};
use crate::postgres::Client;
use crate::responses::Topology;
use crate::QueryCatalog;

use super::version::{get_extension_versions, Version};

const POSTGRES_RECOVERY_KEY: &str = "IsPostgresInRecovery";

pub trait DynamicConfiguration: Send + Sync {
    fn get_str(&self, key: &str) -> Option<&str>;
    fn get_bool(&self, key: &str, default: bool) -> bool;
    fn get_i32(&self, key: &str, default: i32) -> i32;
    fn equals_value(&self, key: &str, value: &str) -> bool;

    fn topology(&self) -> RawBson;

    fn server_version(&self) -> Version {
        self.get_str("serverVersion")
            .and_then(Version::parse)
            .unwrap_or(Version::Seven)
    }

    fn index_build_sleep_milli_secs(&self) -> i32 {
        self.get_i32("indexBuildWaitSleepTimeInMilliSec", 1000)
    }

    fn is_primary(&self) -> bool {
        self.get_bool("IsPrimary", false)
    }

    fn send_shutdown_responses(&self) -> bool {
        self.get_bool("SendShutdownResponses", false)
    }

    fn is_read_only_for_disk_full(&self) -> bool {
        self.get_bool("default_transaction_read_only", false)
            && self.get_bool("IsPgReadOnlyForDiskFull", false)
    }

    fn read_only(&self) -> bool {
        self.get_bool("readOnly", false)
    }

    fn max_write_batch_size(&self) -> i32 {
        self.get_i32("maxWriteBatchSize", 100000)
    }

    fn is_replica_cluster(&self) -> bool {
        (self.get_bool(POSTGRES_RECOVERY_KEY, false)
            && self.equals_value("citus.use_secondary_nodes", "always"))
            || self.get_bool("simulateReadReplica", false)
    }

    fn is_postgres_writable(&self) -> bool {
        !self.get_bool(POSTGRES_RECOVERY_KEY, false)
    }

    fn enable_diagnostic_logging(&self) -> bool {
        self.get_bool("enableMongoRequestsTrace", false)
    }

    fn enable_fulltext_diagnostic_logging(&self) -> bool {
        self.get_bool("enableFullTextQueryInLogs", false)
    }

    fn enable_developer_explain(&self) -> bool {
        self.get_bool("mongoEnableDeveloperExplain", false)
    }

    fn max_connections(&self) -> usize {
        self.get_str("citus.max_connections")
            .and_then(|v| v.parse::<i32>().ok())
            .unwrap_or_else(|| self.get_i32("max_connections", 300)) as usize
    }

    fn enable_data_api_endpoint(&self) -> bool {
        self.get_bool("mongoEnableDataApiEndpoint", false)
    }

    fn enable_change_streams(&self) -> bool {
        self.get_bool("enableChangeStreams", false)
    }

    fn document_service_instance_id(&self) -> String {
        self.get_str("documentServiceInstanceId")
            .map(|s| s.to_string())
            .unwrap_or_default()
    }
}

impl Debug for dyn DynamicConfiguration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "")
    }
}

#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct HostConfig {
    #[serde(default)]
    is_primary: String,
    #[serde(default)]
    send_shutdown_responses: String,
}

// Intended to be used for configurations which can change during runtime.
#[derive(Debug)]
pub struct PgConfiguration {
    topology: Topology,
    configurations: HashMap<String, String>,
}

impl PgConfiguration {
    pub async fn new(
        query_catalog: &QueryCatalog,
        dynamic_config_file: &str,
        client: &Client,
    ) -> Result<Self> {
        let topology = match get_extension_versions(query_catalog, client).await {
            Ok(t) => t,
            Err(e) => {
                log::error!("Failed to acquire topology: {}", e);
                Topology::default()
            }
        };

        let configurations =
            PgConfiguration::load_configurations(dynamic_config_file, query_catalog, client)
                .await?;
        Ok(PgConfiguration {
            configurations,
            topology,
        })
    }

    async fn load_host_config(dynamic_config_file: &str) -> Result<HostConfig> {
        let config: HostConfig =
            serde_json::from_str(&tokio::fs::read_to_string(dynamic_config_file).await?).map_err(
                |e| DocumentDBError::internal_error(format!("Failed to read config file: {}", e)),
            )?;
        Ok(config)
    }

    async fn load_configurations(
        dynamic_config_file: &str,
        query_catalog: &QueryCatalog,
        client: &Client,
    ) -> Result<HashMap<String, String>> {
        let mut configs = HashMap::new();

        match Self::load_host_config(dynamic_config_file).await {
            Ok(host_config) => {
                configs.insert(
                    "IsPrimary".to_owned(),
                    host_config.is_primary.to_lowercase(),
                );
                configs.insert(
                    "SendShutdownResponses".to_owned(),
                    host_config.send_shutdown_responses.to_lowercase(),
                );
            }
            Err(e) => log::warn!("Host Config file not able to be loaded: {}", e),
        }

        let results = client
            .query(query_catalog.pg_settings(), &[], &[], None)
            .await?;
        for row in results {
            let key: &str = row.get(0);
            let key = key.strip_prefix("pgmongo.").unwrap_or(key);

            let mut value: String = row.get(1);
            if value == "on" {
                value = "true".to_string();
            } else if value == "off" {
                value = "false".to_string();
            }
            configs.insert(key.to_owned(), value);
        }

        let result = client
            .query(query_catalog.pg_is_in_recovery(), &[], &[], None)
            .await?;
        let in_recovery: bool = result.first().is_some_and(|row| row.get(0));
        configs.insert(POSTGRES_RECOVERY_KEY.to_string(), in_recovery.to_string());

        log::info!("Dynamic configurations loaded: {:?}", configs);
        Ok(configs)
    }
}

impl DynamicConfiguration for PgConfiguration {
    fn topology(&self) -> RawBson {
        self.topology.to_bson()
    }

    fn get_str(&self, key: &str) -> Option<&str> {
        self.configurations.get(key).map(|x| x.as_str())
    }

    fn get_bool(&self, key: &str, default: bool) -> bool {
        self.configurations
            .get(key)
            .map(|v| v.parse::<bool>().unwrap_or(default))
            .unwrap_or(default)
    }

    fn get_i32(&self, key: &str, default: i32) -> i32 {
        self.configurations
            .get(key)
            .map(|v| v.parse::<i32>().unwrap_or(default))
            .unwrap_or(default)
    }

    fn equals_value(&self, key: &str, value: &str) -> bool {
        self.configurations
            .get(key)
            .map(|v| v == value)
            .unwrap_or(false)
    }
}
