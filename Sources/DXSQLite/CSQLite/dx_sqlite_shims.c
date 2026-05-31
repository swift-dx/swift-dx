//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftDX open source project
//
// Copyright (c) 2026 SwiftDX Contributors
// Licensed under Apache License v2.0. See LICENSE for license information.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#include "dx_sqlite_shims.h"
#include <string.h>

int dx_sqlite3_db_config_int(sqlite3 *connection, int option, int value, int *resultValue) {
    return sqlite3_db_config(connection, option, value, resultValue);
}

int dx_sqlite3_bind_text_transient(sqlite3_stmt *statement, int index, const char *bytes, int byteCount) {
    return sqlite3_bind_text(statement, index, bytes, byteCount, SQLITE_TRANSIENT);
}

int dx_sqlite3_bind_blob_transient(sqlite3_stmt *statement, int index, const void *bytes, int byteCount) {
    return sqlite3_bind_blob(statement, index, bytes, byteCount, SQLITE_TRANSIENT);
}

void dx_sqlite3_result_text_transient(sqlite3_context *context, const char *bytes, int byteCount) {
    sqlite3_result_text(context, bytes, byteCount, SQLITE_TRANSIENT);
}

void dx_sqlite3_result_blob_transient(sqlite3_context *context, const void *bytes, int byteCount) {
    sqlite3_result_blob(context, bytes, byteCount, SQLITE_TRANSIENT);
}

sqlite3_vtab *dx_vtab_alloc(void) {
    dx_vtab *table = (dx_vtab *)sqlite3_malloc((int)sizeof(dx_vtab));
    if (table != 0) {
        memset(table, 0, sizeof(dx_vtab));
    }
    return (sqlite3_vtab *)table;
}

void dx_vtab_free(sqlite3_vtab *table) {
    sqlite3_free(table);
}

void *dx_vtab_box(sqlite3_vtab *table) {
    return ((dx_vtab *)table)->box;
}

void dx_vtab_set_box(sqlite3_vtab *table, void *box) {
    ((dx_vtab *)table)->box = box;
}

sqlite3_vtab_cursor *dx_vtab_cursor_alloc(void) {
    dx_vtab_cursor *cursor = (dx_vtab_cursor *)sqlite3_malloc((int)sizeof(dx_vtab_cursor));
    if (cursor != 0) {
        memset(cursor, 0, sizeof(dx_vtab_cursor));
    }
    return (sqlite3_vtab_cursor *)cursor;
}

void dx_vtab_cursor_free(sqlite3_vtab_cursor *cursor) {
    sqlite3_free(cursor);
}

void *dx_vtab_cursor_box(sqlite3_vtab_cursor *cursor) {
    return ((dx_vtab_cursor *)cursor)->box;
}

void dx_vtab_cursor_set_box(sqlite3_vtab_cursor *cursor, void *box) {
    ((dx_vtab_cursor *)cursor)->box = box;
}

sqlite3_vtab *dx_vtab_cursor_table(sqlite3_vtab_cursor *cursor) {
    return cursor->pVtab;
}
