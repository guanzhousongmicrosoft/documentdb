use std::{borrow::Cow, collections::HashMap, sync::Arc, time::Duration};

use tokio::sync::RwLock;

use crate::{
    configuration::{DynamicConfiguration, PgConfiguration, SetupConfiguration},
    error::{DocumentDBError, Result},
    postgres::{Client, Pool},
    QueryCatalog,
};

use super::{CursorStore, CursorStoreEntry, TransactionStore};

type ClientKey = (Cow<'static, str>, Cow<'static, str>);

pub struct ServiceContextInner {
    pub setup_configuration: SetupConfiguration,
    pub dynamic_configuration: Arc<RwLock<Arc<dyn DynamicConfiguration>>>,
    pub system_pool: Arc<Pool>,
    pub pg_clients: RwLock<HashMap<ClientKey, Pool>>,
    pub cursor_store: CursorStore,
    pub transaction_store: TransactionStore,
    pub query_catalog: QueryCatalog,
}

#[derive(Clone)]
pub struct ServiceContext(Arc<ServiceContextInner>);

impl ServiceContext {
    pub async fn new(
        setup_configuration: &SetupConfiguration,
        dynamic: &mut Option<Box<dyn DynamicConfiguration>>,
        query_catalog: &QueryCatalog,
    ) -> Result<Self> {
        let system_pool = Arc::new(Pool::new_with_user(
            setup_configuration,
            query_catalog,
            setup_configuration
                .postgres_system_user
                .as_ref()
                .map_or("documentdb", |s| s.as_str()),
            None,
            "MongoGateway-SystemRequests",
            5,
        )?);

        log::trace!("Pool initialized");

        // Use a dynamic configuration override if present. This is only passed by integration tests to allow control over configurations
        let dynamic_configuration = if let Some(dynamic) = dynamic.take() {
            Arc::new(RwLock::new(Arc::from(dynamic)))
        } else {
            let client = Client::new(system_pool.get().await?, false);
            let pg_config: Arc<RwLock<Arc<dyn DynamicConfiguration>>> =
                Arc::new(RwLock::new(Arc::new(
                    PgConfiguration::new(
                        query_catalog,
                        &setup_configuration.dynamic_configuration_file,
                        &client,
                    )
                    .await?,
                )));
            Self::start_dynamic_configuration_refresh_thread(
                pg_config.clone(),
                system_pool.clone(),
                query_catalog,
                setup_configuration.dynamic_configuration_file.clone(),
                setup_configuration
                    .dynamic_configuration_refresh_interval_secs
                    .unwrap_or(5 * 60),
            );
            pg_config
        };

        log::trace!("Initial dynamic configuration: {:?}", dynamic_configuration);

        let inner = ServiceContextInner {
            setup_configuration: setup_configuration.clone(),
            dynamic_configuration,
            system_pool,
            pg_clients: RwLock::new(HashMap::new()),
            cursor_store: CursorStore::new(setup_configuration, true),
            transaction_store: TransactionStore::new(Duration::from_secs(
                setup_configuration.transaction_timeout_secs.unwrap_or(30),
            )),
            query_catalog: query_catalog.clone(),
        };
        Ok(ServiceContext(Arc::new(inner)))
    }

    fn start_dynamic_configuration_refresh_thread(
        configuration: Arc<RwLock<Arc<dyn DynamicConfiguration>>>,
        pool: Arc<Pool>,
        query_catalog: &QueryCatalog,
        dynamic_config_file: String,
        refresh_interval: u32,
    ) {
        let query_catalog_clone = query_catalog.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(refresh_interval as u64));
            interval.tick().await;

            loop {
                interval.tick().await;

                match pool.get().await {
                    Ok(client) => {
                        match PgConfiguration::new(
                            &query_catalog_clone,
                            &dynamic_config_file,
                            &Client::new(client, false),
                        )
                        .await
                        {
                            Ok(config) => {
                                let mut config_store = configuration.write().await;
                                *config_store = Arc::new(config)
                            }
                            Err(e) => log::error!("Failed to refresh configuration: {}", e),
                        }
                    }
                    Err(e) => {
                        log::error!("Failed to acquire refresh client: {}", e)
                    }
                }
            }
        });
    }

    pub async fn pg(&'_ self, user: &str, pass: &str) -> Result<Client> {
        let map = self.0.pg_clients.read().await;

        match map.get(&(Cow::Borrowed(user), Cow::Borrowed(pass))) {
            None => Err(DocumentDBError::internal_error(
                "Connection pool missing for user.".to_string(),
            )),
            Some(pool) => {
                let client = pool.get().await?;
                Ok(Client::new(client, false))
            }
        }
    }

    pub async fn add_cursor(&self, key: (i64, String), entry: CursorStoreEntry) {
        self.0.cursor_store.add_cursor(key, entry).await
    }

    pub async fn get_cursor(&self, id: i64, user: &str) -> Option<CursorStoreEntry> {
        self.0.cursor_store.get_cursor((id, user.to_string())).await
    }

    pub async fn invalidate_cursors_by_collection(&self, db: &str, collection: &str) {
        self.0
            .cursor_store
            .invalidate_cursors_by_collection(db, collection)
            .await
    }

    pub async fn invalidate_cursors_by_database(&self, db: &str) {
        self.0.cursor_store.invalidate_cursors_by_database(db).await
    }

    pub async fn invalidate_cursors_by_session(&self, session: &[u8]) {
        self.0
            .cursor_store
            .invalidate_cursors_by_session(session)
            .await
    }

    pub async fn kill_cursors(&self, user: &str, cursors: &[i64]) -> (Vec<i64>, Vec<i64>) {
        self.0
            .cursor_store
            .kill_cursors(user.to_string(), cursors)
            .await
    }

    pub async fn system_client(&self) -> Result<Client> {
        Ok(Client::new(self.0.system_pool.get().await?, false))
    }

    pub fn setup_configuration(&self) -> &SetupConfiguration {
        &self.0.setup_configuration
    }

    pub async fn dynamic_configuration(&self) -> Arc<dyn DynamicConfiguration> {
        self.0.dynamic_configuration.read().await.clone()
    }

    pub fn transaction_store(&self) -> &TransactionStore {
        &self.0.transaction_store
    }

    pub fn query_catalog(&self) -> &QueryCatalog {
        &self.0.query_catalog
    }

    pub async fn ensure_client_pool(&self, user: &str, pass: &str) -> Result<()> {
        if self
            .0
            .pg_clients
            .read()
            .await
            .contains_key(&(Cow::Borrowed(user), Cow::Borrowed(pass)))
        {
            return Ok(());
        }

        let mut map = self.0.pg_clients.write().await;
        let _ = map.insert(
            (Cow::Owned(user.to_owned()), Cow::Owned(pass.to_owned())),
            Pool::new_with_user(
                self.setup_configuration(),
                self.query_catalog(),
                user,
                Some(pass),
                "MongoGateway-Data",
                self.dynamic_configuration().await.max_connections(),
            )?,
        );
        Ok(())
    }
}
