/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/transaction_timeout_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use std::time::Duration;

use bson::doc;
use documentdb_gateway_core::configuration::DocumentDBSetupConfiguration;
use documentdb_tests::test_setup::{clients, config::setup_configuration, initialize};
use mongodb::error::{Error, ErrorKind};

#[tokio::test]
async fn setup_transaction_timeout_aborts_idle_transaction() -> Result<(), Error> {
    let client = initialize::initialize_with_config(DocumentDBSetupConfiguration {
        transaction_timeout_secs: Some(2),
        ..setup_configuration()
    })
    .await?;
    let db = clients::setup_db(&client, "setup_transaction_timeout").await?;
    let coll = db.collection("test");

    let mut session = client.start_session().await?;
    session.start_transaction().await?;
    coll.insert_one(doc! { "_id": 1 })
        .session(&mut session)
        .await?;

    tokio::time::sleep(Duration::from_secs(6)).await;

    match session.commit_transaction().await {
        Err(e) => {
            if let ErrorKind::Command(ref cmd_err) = *e.kind {
                assert_eq!(
                    cmd_err.code, 251,
                    "Expected NoSuchTransaction (251) after the transaction timed out, got: {}",
                    cmd_err.code
                );
            } else {
                panic!("Expected a Command error with code 251, got: {e:?}");
            }
        }
        Ok(()) => panic!("Expected commit to fail after TransactionTimeoutSecs elapsed"),
    }

    assert_eq!(coll.count_documents(doc! {}).await?, 0);
    Ok(())
}
