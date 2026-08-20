/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/constant.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt::Display;

#[must_use]
pub fn value_access_error_message() -> String {
    "Value Access Error.".to_owned()
}

#[must_use]
pub fn documentdb_error_message() -> String {
    "DocumentDB error.".to_owned()
}

pub fn pg_returned_invalid_response_message<E: Display>(error: E) -> String {
    format!("PG returned invalid response: {error}.")
}

#[must_use]
pub const fn duplicate_key_violation_message() -> &'static str {
    "Duplicate key violation on the requested collection."
}

#[must_use]
pub const fn generic_internal_error_message() -> &'static str {
    "An unexpected internal error has occurred."
}

/// The single message returned for every failed authentication attempt.
///
/// Matches `MongoDB`'s wording so that existing client code, tutorials, and
/// troubleshooting guides apply unchanged. It is deliberately identical for a
/// bad password and for an unknown user: distinguishing them turns the
/// endpoint into a username-enumeration oracle for an unauthenticated caller.
/// Keep the specific cause in the internal/log-side message, never in the
/// wire response.
#[must_use]
pub const fn authentication_failed_message() -> &'static str {
    "Authentication failed."
}
