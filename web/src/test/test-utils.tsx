// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

/* eslint-disable lingui/no-unlocalized-strings */
// The render wrapper and every fixture over the shared object model live in
// @mochi/web — see components/entity/entity-test-utils. Only the CRM container and the
// details envelope are app-specific, so only those are built here.
import {
  createMockEntityClass,
  createMockEntityDesign,
  createMockEntityField,
} from "@mochi/web/components/entity/entity-test-utils";
import type { Crm, CrmDetails } from "@/types";

export * from "@mochi/web/components/entity/entity-test-utils";

export {
  createMockEntityClass as createMockClass,
  createMockEntityField as createMockField,
};

function createMockCrm(overrides?: Partial<Crm>): Crm {
  return {
    id: "crm-1",
    fingerprint: "abc123def",
    name: "Test Crm",
    description: "A test crm",
    owner: { local: true, name: "testuser" },
    server: "local",
    created: Date.now(),
    updated: Date.now(),
    ...overrides,
  };
}

export function createMockCrmDetails(
  overrides?: Partial<CrmDetails>,
): CrmDetails {
  return { crm: { ...createMockCrm(), populated: 1, access: "owner" }, ...createMockEntityDesign(), ...overrides };
}
