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
  createMockEntityObject,
  createMockEntityOption,
  createMockEntityField,
  createMockEntityView,
} from "@mochi/web/components/entity/entity-test-utils";
import type { Crm, CrmDetails, CrmObject } from "@/types";

export * from "@mochi/web/components/entity/entity-test-utils";

export {
  createMockEntityClass as createMockClass,
  createMockEntityField as createMockField,
  createMockEntityOption as createMockOption,
  createMockEntityView as createMockView,
};

export function createMockCrm(overrides?: Partial<Crm>): Crm {
  return {
    id: "proj-1",
    fingerprint: "abc123def",
    name: "Test Crm",
    description: "A test crm",
    owner: 1,
    ownername: "testuser",
    server: "local",
    created: Date.now(),
    updated: Date.now(),
    populated: 1,
    access: "owner",
    ...overrides,
  };
}

export function createMockObject(overrides?: Partial<CrmObject>): CrmObject {
  return { ...createMockEntityObject(), crm: "proj-1", ...overrides };
}

export function createMockObjects(count: number): CrmObject[] {
  return Array.from({ length: count }, (_, i) =>
    createMockObject({
      id: `obj-${i + 1}`,
      values: {
        title: `Task ${i + 1}`,
        status: ["todo", "in_progress", "done"][i % 3],
        priority: ["high", "medium", "low"][i % 3],
      },
    }),
  );
}

export function createMockCrmDetails(
  overrides?: Partial<CrmDetails>,
): CrmDetails {
  return { crm: createMockCrm(), ...createMockEntityDesign(), ...overrides };
}
