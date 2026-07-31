// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The object model itself is shared with the projects app — see
// @mochi/web types/entity-object. Only the CRM container and the response
// envelopes are app-specific and defined here.
import type {
  EntityAccess,
  EntityActivity,
  EntityAttachment,
  EntityChecklistItem,
  EntityClass,
  EntityComment,
  EntityField,
  EntityFieldOption,
  EntityObject,
  EntityObjectLink,
  EntitySortState,
  EntityView,
  EntityWatcher,
} from "@mochi/web";

// Crm types
export type CrmAccess = EntityAccess;

export interface Crm {
  id: string;
  fingerprint: string;
  name: string;
  description: string;
  owner: number;
  ownername: string;
  server: string;
  created: number;
  updated: number;
  // 0 while a freshly-subscribed CRM's bulk content is still arriving over P2P;
  // 1 once it has landed. The board shows a loading state until then.
  populated: number;
  access: CrmAccess;
}

export type CrmClass = EntityClass;
export type CrmField = EntityField;
export type FieldOption = EntityFieldOption;
export type CrmView = EntityView;

export interface CrmDetails {
  crm: Crm;
  classes: CrmClass[];
  fields: Record<string, CrmField[]>;
  options: Record<string, Record<string, FieldOption[]>>;
  views: CrmView[];
  hierarchy: Record<string, string[]>;
}

// Object types
export type CrmObject = EntityObject & { crm: string };

export type ObjectLink = EntityObjectLink;
export type CommentAttachment = EntityAttachment;
export type Comment = EntityComment;
export type Attachment = EntityAttachment;
export type ChecklistItem = EntityChecklistItem;
export type Activity = EntityActivity;
export type Watcher = EntityWatcher;

// Sort state for views
export type SortState = EntitySortState;

// API Response types
export interface ObjectListResponse {
  data: {
    objects: CrmObject[];
    watched?: string[];
  };
}

export interface ObjectCreateResponse {
  data: {
    id: string;
  };
}

export interface ObjectGetResponse {
  data: {
    object: CrmObject;
    values: Record<string, string>;
    outgoing: ObjectLink[];
    incoming: ObjectLink[];
    watching: boolean;
    comment_count: number;
  };
}

export interface CommentListResponse {
  data: {
    comments: Comment[];
    count: number;
  };
}

export interface ActivityListResponse {
  data: {
    activities: Activity[];
  };
}

export interface AttachmentListResponse {
  data: {
    attachments: Attachment[];
  };
}

export interface WatcherListResponse {
  data: {
    watchers: Watcher[];
    watching: boolean;
  };
}

export interface LinkListResponse {
  data: {
    outgoing: ObjectLink[];
    incoming: ObjectLink[];
  };
}
