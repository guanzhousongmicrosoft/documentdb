/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/rbac_hooks_def.h
 *
 * Definition of the hook that settles the permission identity of a plan built
 * without the planner. A layer that implements it registers itself here; a
 * caller that only invokes it includes rbac_hooks.h instead.
 *
 *-------------------------------------------------------------------------
 */

#ifndef EXTENSION_RBAC_HOOKS_DEF_H
#define EXTENSION_RBAC_HOOKS_DEF_H

#include <nodes/parsenodes.h>
#include <nodes/plannodes.h>

typedef void (*ApplyCollectionAccessIdentityToPlan_HookType)(RangeTblEntry *rte,
															 PlannedStmt *stmt);
extern ApplyCollectionAccessIdentityToPlan_HookType
	apply_collection_access_identity_to_plan_hook;

#endif
