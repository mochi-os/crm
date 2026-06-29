// Copyright © 2026 Mochi OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// Crm types
export type CrmAccess = "owner" | "design" | "write" | "comment" | "view";

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

export interface CrmClass {
  id: string;
  name: string;
  rank: number;
  title: string;
}

export interface CrmField {
  id: string;
  name: string;
  fieldtype: string;
  flags: string;
  multi: number;
  rank: number;
  card: number;
  position: string;
  rows: number;
  pattern?: string;
  minlength?: number;
  maxlength?: number;
}

export interface FieldOption {
  id: string;
  name: string;
  colour: string;
  icon: string;
  rank: number;
}

export interface CrmView {
  id: string;
  name: string;
  viewtype: string;
  filter: string;
  columns: string;
  rows: string;
  fields: string;
  sort: string;
  direction: string;
  classes: string[];
  rank: number;
  border: string;
}

export interface CrmDetails {
  crm: Crm;
  classes: CrmClass[];
  fields: Record<string, CrmField[]>;
  options: Record<string, Record<string, FieldOption[]>>;
  views: CrmView[];
  hierarchy: Record<string, string[]>;
}

// Object types
export interface CrmObject {
  id: string;
  crm: string;
  class: string;
  parent: string;
  // Fractional-index ordering key (#53): an opaque base-62 string, compared
  // lexicographically. Not a position — the move action still sends a 1-based
  // target index, the server computes the key.
  rank: string;
  created: number;
  updated: number;
  values: Record<string, string>;
}

export interface ObjectLink {
  target?: string;
  source?: string;
  linktype: string;
  created: number;
  type?: string;
  title?: string;
}

export interface CommentAttachment {
  id: string;
  name: string;
  size: number;
  type: string;
  created: number;
}

export interface Comment {
  id: string;
  parent: string;
  author: string;
  name: string;
  content: string;
  created: number;
  edited: number;
  children: Comment[];
  attachments: CommentAttachment[];
}

export interface Attachment {
  id: string;
  name: string;
  size: number;
  type: string;
  created: number;
}

export interface ChecklistItem {
  id: string;
  text: string;
  done: boolean;
}

export interface Activity {
  id: string;
  user: string;
  name: string;
  action: string;
  field: string;
  oldvalue: string;
  newvalue: string;
  created: number;
}

export interface Watcher {
  user: string;
  created: number;
}

// Sort state for views
export interface SortState {
  field: string;
  direction: "asc" | "desc";
}

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

