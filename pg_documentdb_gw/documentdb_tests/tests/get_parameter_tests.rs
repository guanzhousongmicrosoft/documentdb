/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/get_parameter_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use documentdb_tests::{
    test_setup::{clients, initialize},
    utils::commands::execute_command_and_validate_error,
};
use mongodb::error::Error;

#[tokio::test]
async fn get_parameter_is_not_supported() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let admin = client.database("admin");

    for command in [
        doc! { "getParameter": 1, "featureCompatibilityVersion": 1 },
        doc! { "getParameter": "*" },
        doc! { "getParameter": { "allParameters": true } },
        doc! { "getParameter": { "showDetails": true }, "featureCompatibilityVersion": 1 },
        doc! { "getParameter": 1, "unknownParameter": 1 },
    ] {
        execute_command_and_validate_error(
            &admin,
            command,
            115,
            "Command 'getParameter' not supported.",
            "CommandNotSupported",
        )
        .await;
    }

    admin.run_command(doc! { "ping": 1 }).await?;
    Ok(())
}

#[tokio::test]
async fn get_parameter_requires_admin_database() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = client.database("get_parameter_tests");

    for command in [
        doc! { "getParameter": 1, "featureCompatibilityVersion": 1 },
        doc! { "getParameter": "*" },
        doc! { "getParameter": { "allParameters": true, "showDetails": true } },
    ] {
        execute_command_and_validate_error(
            &db,
            command,
            13,
            "getParameter may only be run against the admin database.",
            "Unauthorized",
        )
        .await;
    }
    Ok(())
}

#[tokio::test]
async fn get_parameter_validates_options() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let admin = client.database("admin");

    for (command, message) in [
        (
            doc! { "getParameter": { "allParameters": "invalid" } },
            "allParameters should be a bool",
        ),
        (
            doc! { "getParameter": { "showDetails": "invalid" } },
            "showDetails should be convertible to a bool",
        ),
    ] {
        execute_command_and_validate_error(&admin, command, 14, message, "TypeMismatch").await;
    }
    Ok(())
}

#[tokio::test]
async fn get_parameter_requires_authentication() -> Result<(), Error> {
    let _ = initialize::initialize().await?;
    let client = clients::get_client_unauthenticated()?;

    execute_command_and_validate_error(
        &client.database("admin"),
        doc! { "getParameter": 1, "featureCompatibilityVersion": 1 },
        13,
        "connection is not authenticated yet.",
        "Unauthorized",
    )
    .await;
    Ok(())
}
