// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The object model itself is shared with the projects app — see
// @mochi/web types/entity-object. Only the CRM container and the response
// envelopes are app-specific and defined here.
import type {
  EntityAccess,
  EntityAttachment,
  EntityClass,
  EntityComment,
  EntityField,
  EntityFieldOption,
  EntityObject,
  EntityObjectLink,
  EntityView,
} from "@mochi/web";

// Crm types
export type CrmAccess = EntityAccess;

export interface Crm {
  id: string;
  fingerprint: string;
  name: string;
  description: string;
  owner: { local: boolean; name: string };
  server: string;
  created: number;
  updated: number;
}

export type CrmClass = EntityClass;
export type CrmField = EntityField;
export type FieldOption = EntityFieldOption;
export type CrmView = EntityView;

// The list endpoint emits a Crm; -/info adds the two fields only the detail
// load knows.
export interface CrmDetails {
  crm: Crm & {
    // 0 while a freshly-subscribed CRM's bulk content is still arriving over
    // P2P; 1 once it has landed. The board shows a loading state until then.
    populated: number;
    access: CrmAccess;
  };
  classes: CrmClass[];
  fields: Record<string, CrmField[]>;
  options: Record<string, Record<string, FieldOption[]>>;
  views: CrmView[];
  hierarchy: Record<string, string[]>;
}

// Object types
export type CrmObject = EntityObject & { crm: string };

export type ObjectLink = EntityObjectLink;
export type Comment = EntityComment;
export type Attachment = EntityAttachment;

