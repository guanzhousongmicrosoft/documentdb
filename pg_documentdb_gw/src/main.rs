use log::info;
use simple_logger::SimpleLogger;
use std::{env, path::PathBuf};

use documentdb_gateway::{
    configuration::SetupConfiguration, get_service_context, populate_ssl_certificates,
    postgres::create_query_catalog, run_server,
};
use tokio_util::sync::CancellationToken;

#[ntex::main]
async fn main() {
    // Takes the configuration file as an argument
    let cfg_file = if let Some(arg1) = env::args().nth(1) {
        PathBuf::from(arg1)
    } else {
        // Defaults to the source directory for local runs
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("SetupConfiguration.json")
    };

    let token = CancellationToken::new();

    let setup_configuration = SetupConfiguration::new(&cfg_file)
        .await
        .expect("Failed to load configuration.");

    SimpleLogger::new()
        .with_level(log::LevelFilter::Info)
        .with_module_level("tokio_postgres", log::LevelFilter::Info)
        .init()
        .expect("Failed to start logger");

    let service_context =
        get_service_context(setup_configuration.clone(), None, create_query_catalog())
            .await
            .unwrap();

    let certificate_options = if let Some(co) = service_context
        .setup_configuration()
        .certificate_options
        .clone()
    {
        co
    } else {
        populate_ssl_certificates().await.unwrap()
    };

    info!(
        "Starting server with configuration: {:?}",
        setup_configuration
    );
    run_server(service_context, certificate_options, None, token.clone())
        .await
        .unwrap();
}
