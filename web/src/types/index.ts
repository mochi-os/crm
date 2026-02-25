// Crm types
export type CrmAccess = "owner" | "design" | "write" | "comment" | "view";

export interface Crm {
  id: string;
  fingerprint: string;
  name: string;
  description: string;
  prefix: string;
  counter: number;
  owner: number;
  ownername: string;
  server: string;
  created: number;
  updated: number;
  access: CrmAccess;
}

export interface CrmClass {
  id: string;
  name: string;
  rank: number;
  requests: string;
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
  number: number;
  parent: string;
  rank: number;
  created: number;
  updated: number;
  readable?: string;
  values: Record<string, string>;
}

export interface ObjectLink {
  target?: string;
  source?: string;
  linktype: string;
  created: number;
  number?: number;
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

// Field flag check helper
export function fieldHasFlag(field: { flags?: string }, flag: string): boolean {
  return field.flags?.split(",").includes(flag) ?? false;
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
    number: number;
    readable: string;
  };
}

export interface ObjectGetResponse {
  data: {
    object: CrmObject & { readable: string };
    values: Record<string, string>;
    links: ObjectLink[];
    linked_by: ObjectLink[];
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

