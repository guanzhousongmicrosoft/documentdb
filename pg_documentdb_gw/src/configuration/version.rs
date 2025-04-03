use bson::RawArrayBuf;

use crate::error::{DocumentDBError, Result};
use crate::postgres::Client;
use crate::responses::Topology;
use crate::QueryCatalog;

pub enum Version {
    FourTwo,
    Five,
    Six,
    Seven,
}

impl Version {
    pub fn parse(val: &str) -> Option<Version> {
        match val {
            "4.2" => Some(Version::FourTwo),
            "5.0" => Some(Version::Five),
            "6.0" => Some(Version::Six),
            "7.0" => Some(Version::Seven),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &str {
        match self {
            Version::FourTwo => "4.2.0",
            Version::Five => "5.0.0",
            Version::Six => "6.0.0",
            Version::Seven => "7.0.0",
        }
    }

    pub fn as_array(&self) -> [i32; 4] {
        match self {
            Version::FourTwo => [4, 2, 0, 0],
            Version::Five => [5, 0, 0, 0],
            Version::Six => [6, 0, 0, 0],
            Version::Seven => [7, 0, 0, 0],
        }
    }

    pub fn as_bson_array(&self) -> RawArrayBuf {
        let mut array = RawArrayBuf::new();
        let versions = self.as_array();
        for v in versions {
            array.push(v)
        }
        array
    }

    pub fn max_wire_protocol(&self) -> i32 {
        match self {
            Version::FourTwo => 8,
            Version::Five => 13,
            Version::Six => 17,
            Version::Seven => 21,
        }
    }
}

// Get version information from the backend
pub async fn get_extension_versions(
    query_catalog: &QueryCatalog,
    client: &Client,
) -> Result<Topology> {
    let results = client
        .query(query_catalog.extension_versions(), &[], &[], None)
        .await?;
    let result = results.first().ok_or(DocumentDBError::internal_error(
        "Didn't get any results for extension version".to_string(),
    ))?;
    let fields: [&str; 6] = result.try_get(0)?;
    let topology = Topology {
        cluster_version: fields[0].to_string(),
        binary_version: fields[1].to_string(),
        citus_simple_version: fields[2].to_string(),
        postgres_version: fields[3].to_string(),
        binary_extended_version: fields[4].to_string(),
        citus_extended_version: fields[5].to_string(),
    };
    log::info!("Topology acquired: {:?}", topology);
    Ok(topology)
}
