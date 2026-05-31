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

#ifndef DX_SQLITE_SHIMS_H
#define DX_SQLITE_SHIMS_H

// These feature flags gate API declarations inside sqlite3.h (not just the
// implementation). They are defined here, before the include, so the symbols
// are visible to Swift importers of the CSQLite module — a target's cSettings
// define only reaches the compilation of sqlite3.c, not the parse of its
// headers by importers. The matching cSettings defines build the same features
// into sqlite3.c.
#ifndef SQLITE_ENABLE_SESSION
#define SQLITE_ENABLE_SESSION 1
#endif
#ifndef SQLITE_ENABLE_PREUPDATE_HOOK
#define SQLITE_ENABLE_PREUPDATE_HOOK 1
#endif

#include "sqlite3.h"

int dx_sqlite3_db_config_int(sqlite3 *connection, int option, int value, int *resultValue);

int dx_sqlite3_bind_text_transient(sqlite3_stmt *statement, int index, const char *bytes, int byteCount);

int dx_sqlite3_bind_blob_transient(sqlite3_stmt *statement, int index, const void *bytes, int byteCount);

void dx_sqlite3_result_text_transient(sqlite3_context *context, const char *bytes, int byteCount);

void dx_sqlite3_result_blob_transient(sqlite3_context *context, const void *bytes, int byteCount);

// A virtual-table instance and cursor each embed SQLite's required base struct
// as their first member, so a pointer to the whole struct and a pointer to its
// base are interchangeable. The trailing box holds a retained Swift object (the
// table registration or the cursor's row snapshot) reached through the
// accessors below. These accessors keep the layout casts on the C side so the
// Swift thunks never reinterpret raw pointers.
typedef struct dx_vtab {
    sqlite3_vtab base;
    void *box;
} dx_vtab;

typedef struct dx_vtab_cursor {
    sqlite3_vtab_cursor base;
    void *box;
} dx_vtab_cursor;

sqlite3_vtab *dx_vtab_alloc(void);
void dx_vtab_free(sqlite3_vtab *table);
void *dx_vtab_box(sqlite3_vtab *table);
void dx_vtab_set_box(sqlite3_vtab *table, void *box);

sqlite3_vtab_cursor *dx_vtab_cursor_alloc(void);
void dx_vtab_cursor_free(sqlite3_vtab_cursor *cursor);
void *dx_vtab_cursor_box(sqlite3_vtab_cursor *cursor);
void dx_vtab_cursor_set_box(sqlite3_vtab_cursor *cursor, void *box);
sqlite3_vtab *dx_vtab_cursor_table(sqlite3_vtab_cursor *cursor);

#endif
