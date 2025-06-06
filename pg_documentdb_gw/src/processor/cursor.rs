/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/processor/cursor.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use bson::{rawdoc, RawArrayBuf};
use tokio_postgres::types::Type;

use crate::{
    context::{ConnectionContext, Cursor, CursorStoreEntry},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{Connection, PgDocument, Timeout},
    protocol::OK_SUCCEEDED,
    requests::{Request, RequestInfo},
    responses::{PgResponse, RawResponse, Response},
};

pub async fn save_cursor(
    conn_context: &ConnectionContext,
    conn: Arc<Connection>,
    response: &PgResponse,
    request_info: &RequestInfo<'_>,
) -> Result<()> {
    if let Some((persist, cursor)) = response.get_cursor()? {
        let conn = if persist { Some(conn) } else { None };
        conn_context
            .add_cursor(
                conn,
                cursor,
                conn_context.auth_state.username()?,
                request_info.db()?,
                request_info.collection()?,
                request_info.session_id.map(|v| v.to_vec()),
            )
            .await;
    }
    Ok(())
}

pub async fn process_kill_cursors(
    request: &Request<'_>,
    context: &ConnectionContext,
) -> Result<Response> {
    let _ = request
        .document()
        .get_str("killCursors")
        .map_err(DocumentDBError::parse_failure())?;

    let cursors = request
        .document()
        .get("cursors")?
        .ok_or(DocumentDBError::bad_value(
            "killCursors should have a cursors field".to_string(),
        ))?
        .as_array()
        .ok_or(DocumentDBError::documentdb_error(
            ErrorCode::TypeMismatch,
            "KillCursors cursors should be an array".to_string(),
        ))?;

    let mut cursor_ids = Vec::new();
    for value in cursors {
        let cursor = value?.as_i64().ok_or(DocumentDBError::bad_value(
            "Cursor was not a valid i64".to_string(),
        ))?;
        cursor_ids.push(cursor);
    }
    let (removed_cursors, missing_cursors) = context
        .service_context
        .kill_cursors(context.auth_state.username()?, &cursor_ids)
        .await;
    let mut removed_cursor_buf = RawArrayBuf::new();
    for cursor in removed_cursors {
        removed_cursor_buf.push(cursor);
    }
    let mut missing_cursor_buf = RawArrayBuf::new();
    for cursor in missing_cursors {
        missing_cursor_buf.push(cursor);
    }

    Ok(Response::Raw(RawResponse(rawdoc! {
        "ok":OK_SUCCEEDED,
        "cursorsKilled": removed_cursor_buf,
        "cursorsNotFound": missing_cursor_buf,
        "cursorsAlive": [],
        "cursorsUnknown":[],
    })))
}

pub async fn process_get_more(
    request: &Request<'_>,
    request_info: &mut RequestInfo<'_>,
    conn_context: &ConnectionContext,
) -> Result<Response> {
    let mut id = None;
    request.extract_fields(|k, v| {
        if k == "getMore" {
            id = Some(v.as_i64().ok_or(DocumentDBError::bad_value(
                "getMore value should be an i64".to_string(),
            ))?)
        }
        Ok(())
    })?;
    let id = id.ok_or(DocumentDBError::bad_value(
        "getMore not present in document".to_string(),
    ))?;
    let CursorStoreEntry {
        conn: cursor_conn,
        cursor,
        db,
        collection,
        session_id,
        ..
    } = conn_context
        .get_cursor(id, conn_context.auth_state.username()?)
        .await
        .ok_or(DocumentDBError::documentdb_error(
            ErrorCode::CursorNotFound,
            "Provided cursor not found.".to_string(),
        ))?;

    let persist = cursor_conn.is_some();
    let conn = if let Some(conn) = cursor_conn {
        conn
    } else {
        conn_context.pull_connection().await?
    };

    let results = conn
        .query(
            conn_context
                .service_context
                .query_catalog()
                .cursor_get_more(),
            &[Type::TEXT, Type::BYTEA, Type::BYTEA],
            &[
                &db,
                &PgDocument(request.document()),
                &PgDocument(&cursor.continuation),
            ],
            Timeout::command(request_info.max_time_ms),
            request_info,
        )
        .await?;

    if let Some(row) = results.first() {
        let continuation: Option<PgDocument> = row.try_get(1)?;
        if let Some(continuation) = continuation {
            conn_context
                .add_cursor(
                    if persist { Some(conn) } else { None },
                    Cursor {
                        cursor_id: id,
                        continuation: continuation.0.to_raw_document_buf(),
                    },
                    conn_context.auth_state.username()?,
                    &db,
                    &collection,
                    session_id,
                )
                .await;
        }
    }

    Ok(Response::Pg(PgResponse::new(results)))
}
