/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/authentication_failure_tests.rs
 *
 *-------------------------------------------------------------------------
 */

//! Every failed authentication must report the same user-visible message.
//!
//! Two properties are asserted here:
//!
//! 1. The message reads like an authentication failure. It used to be
//!    `Invalid key`, which reads like a TLS/certificate problem and sends
//!    users looking in the wrong place.
//! 2. A wrong password and an unknown user are indistinguishable. Returning
//!    different messages let an unauthenticated caller enumerate valid
//!    usernames.

use documentdb_gateway_core::responses::constant::authentication_failed_message;
use documentdb_tests::test_setup::{clients, initialize};
use mongodb::{bson::doc, error::Error};

/// Drives an authentication attempt and returns the resulting error message.
async fn auth_error_message(username: &str, password: &str) -> String {
    let Ok(client) = clients::get_client_with_credentials(username, password) else {
        panic!("could not construct a client for user '{username}'")
    };

    let result = client
        .database("admin")
        .run_command(doc! { "listDatabases": 1 })
        .await;

    match result {
        Ok(_) => panic!("authentication unexpectedly succeeded for user '{username}'"),
        Err(e) => e.to_string(),
    }
}

#[tokio::test]
async fn wrong_password_reports_authentication_failure() -> Result<(), Error> {
    let _ = initialize::initialize().await?;

    let message = auth_error_message(clients::TEST_USERNAME, "definitely-not-the-password").await;

    assert!(
        message.contains(authentication_failed_message()),
        "wrong-password error should contain {:?}, got {message:?}",
        authentication_failed_message()
    );
    assert!(
        !message.contains("Invalid key"),
        "wrong-password error should no longer say 'Invalid key', got {message:?}"
    );

    Ok(())
}

#[tokio::test]
async fn unknown_user_reports_authentication_failure() -> Result<(), Error> {
    let _ = initialize::initialize().await?;

    let message = auth_error_message("no_such_user_9c1f2a", "any-password").await;

    assert!(
        message.contains(authentication_failed_message()),
        "unknown-user error should contain {:?}, got {message:?}",
        authentication_failed_message()
    );
    assert!(
        !message.contains("User details not found"),
        "unknown-user error must not disclose that the account does not exist, got {message:?}"
    );

    Ok(())
}

/// The enumeration guard: an unauthenticated caller must not be able to tell a
/// valid username with a bad password apart from a username that does not
/// exist. If these two messages ever diverge again, the endpoint becomes a
/// username oracle.
#[tokio::test]
async fn wrong_password_and_unknown_user_are_indistinguishable() -> Result<(), Error> {
    let _ = initialize::initialize().await?;

    let wrong_password = auth_error_message(clients::TEST_USERNAME, "definitely-not-the-password")
        .await
        .replace(clients::TEST_USERNAME, "<user>");
    let unknown_user = auth_error_message("no_such_user_9c1f2a", "definitely-not-the-password")
        .await
        .replace("no_such_user_9c1f2a", "<user>");

    assert_eq!(
        wrong_password, unknown_user,
        "a bad password and an unknown user must produce the same error, \
         otherwise valid usernames can be enumerated"
    );

    Ok(())
}
