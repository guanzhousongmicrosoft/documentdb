use bson::{rawbson, RawBson};
use serde::Serialize;

#[derive(Debug, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Topology {
    pub cluster_version: String,
    pub binary_version: String,
    pub citus_simple_version: String,

    #[serde(skip_serializing)]
    pub postgres_version: String,

    #[serde(skip_serializing)]
    pub binary_extended_version: String,

    #[serde(skip_serializing)]
    pub citus_extended_version: String,
}

impl Topology {
    pub fn to_bson(&self) -> RawBson {
        rawbson! ({
            "cosmos_versions": [
                self.cluster_version.as_str(),
                self.binary_version.as_str(),
                self.citus_simple_version.as_str()
            ]
        })
    }
}
