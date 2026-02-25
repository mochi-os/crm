import endpoints from "./endpoints";
import { crmsRequest } from "./request";
import type { AccessRule } from "@mochi/common";
import type {
  Crm,
  CrmDetails,
  CrmView,
  CrmClass,
  CrmField,
  FieldOption,
  ObjectListResponse,
  ObjectCreateResponse,
  ObjectGetResponse,
  CommentListResponse,
  ActivityListResponse,
  AttachmentListResponse,
  WatcherListResponse,
  LinkListResponse,
  Comment,
} from "@/types";

// Response types
interface CrmListResponse {
  data: {
    crms: Crm[];
  };
}

interface CrmCreateResponse {
  data: {
    id: string;
    fingerprint: string;
  };
}

interface CrmGetResponse {
  data: CrmDetails;
}

interface SuccessResponse {
  data: {
    success: boolean;
  };
}

interface ViewListResponse {
  data: {
    views: CrmView[];
  };
}

interface ViewCreateResponse {
  data: {
    id: string;
    name: string;
    viewtype: string;
  };
}

// Request types
interface CreateCrmRequest {
  name: string;
  description?: string;
  prefix?: string;
  privacy?: "public" | "private";
}

interface UpdateCrmRequest {
  name?: string;
  description?: string;
  prefix?: string;
}

interface CreateObjectRequest {
  class: string;
  title?: string;
  template?: string;
  parent?: string;
}

interface MoveObjectRequest {
  field?: string;  // Column field name (e.g., "status" or "column")
  value?: string;  // New column value
  rank?: number;
  row_field?: string;  // Row field name (for swimlane moves)
  row_value?: string;  // New row value
  scope_parent?: string;  // Scope rank renumbering to siblings of this parent
  promote?: string;  // "true" to clear parent (promote child to top-level)
}

interface CreateViewRequest {
  name: string;
  viewtype?: "board" | "list";
  filter?: string;
  columns?: string;
  rows?: string;
  fields?: string;
  sort?: string;
  direction?: "asc" | "desc";
  classes?: string;
  border?: string;
}

interface UpdateViewRequest {
  name?: string;
  viewtype?: "board" | "list";
  filter?: string;
  columns?: string;
  rows?: string;
  fields?: string;
  sort?: string;
  direction?: "asc" | "desc";
  classes?: string;
  border?: string;
}

// Class response/request types
interface ClassListResponse {
  data: {
    classes: CrmClass[];
  };
}

interface ClassCreateResponse {
  data: {
    id: string;
    name: string;
    sort: number;
  };
}

interface CreateClassRequest {
  name: string;
  requests?: string;
  title?: string;
}

interface UpdateClassRequest {
  name?: string;
  requests?: string;
  title?: string;
}

// Hierarchy response/request types
interface HierarchyGetResponse {
  data: {
    parents: string[];
  };
}

interface SetHierarchyRequest {
  parents: string;
}

// Field response/request types
interface FieldListResponse {
  data: {
    fields: CrmField[];
  };
}

interface FieldCreateResponse {
  data: {
    id: string;
    name: string;
    fieldtype: string;
    sort: number;
  };
}

interface CreateFieldRequest {
  name: string;
  fieldtype?: string;
  flags?: string;
  multi?: string;
  card?: string;
  rows?: string;
}

interface UpdateFieldRequest {
  id?: string;
  name?: string;
  flags?: string;
  multi?: string;
  card?: string;
  min?: string;
  max?: string;
  pattern?: string;
  minlength?: string;
  maxlength?: string;
  prefix?: string;
  suffix?: string;
  format?: string;
  position?: string;
  rows?: string;
}

// Option response/request types
interface OptionListResponse {
  data: {
    options: FieldOption[];
  };
}

interface OptionCreateResponse {
  data: {
    id: string;
    name: string;
    colour: string;
    sort: number;
  };
}

interface CreateOptionRequest {
  name: string;
  colour?: string;
  icon?: string;
}

interface UpdateOptionRequest {
  name?: string;
  colour?: string;
  icon?: string;
}

// Search response type
interface DirectoryEntry {
  id: string;
  name: string;
  fingerprint: string;
  location?: string;
}

interface SearchResponse {
  data: DirectoryEntry[];
}

// API methods
const crmsApi = {
  // List all crms
  list: async (): Promise<CrmListResponse> => {
    return crmsRequest.get<CrmListResponse>(endpoints.crms.list);
  },

  // Search for crms in the directory
  search: async (params: { search: string }): Promise<SearchResponse> => {
    return crmsRequest.get<SearchResponse>(
      `${endpoints.crms.search}?search=${encodeURIComponent(params.search)}`
    );
  },

  // Create a new CRM
  create: async (
    data: CreateCrmRequest,
  ): Promise<CrmCreateResponse> => {
    return crmsRequest.post<CrmCreateResponse, CreateCrmRequest>(
      endpoints.crms.create,
      data,
    );
  },

  // Get crm details
  get: async (crmId: string): Promise<CrmGetResponse> => {
    return crmsRequest.get<CrmGetResponse>(
      endpoints.crms.info(crmId),
    );
  },

  // Update crm
  update: async (
    crmId: string,
    data: UpdateCrmRequest,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse, UpdateCrmRequest>(
      endpoints.crms.update(crmId),
      data,
    );
  },

  // Delete crm
  delete: async (crmId: string): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.delete(crmId),
    );
  },

  // List crm members (subscribers + owners)
  listPeople: async (
    crmId: string,
  ): Promise<{ data: { people: { id: string; name: string }[] } }> => {
    return crmsRequest.get(endpoints.crms.people(crmId));
  },

  // ============= Object Methods =============

  // List objects
  listObjects: async (
    crmId: string,
    params?: { class?: string; status?: string; parent?: string },
  ): Promise<ObjectListResponse> => {
    const searchParams = new URLSearchParams();
    if (params?.class) searchParams.set("class", params.class);
    if (params?.status) searchParams.set("status", params.status);
    if (params?.parent !== undefined) searchParams.set("parent", params.parent);
    const query = searchParams.toString();
    const url =
      endpoints.crms.objects(crmId) + (query ? `?${query}` : "");
    return crmsRequest.get<ObjectListResponse>(url);
  },

  // Create object
  createObject: async (
    crmId: string,
    data: CreateObjectRequest,
  ): Promise<ObjectCreateResponse> => {
    return crmsRequest.post<ObjectCreateResponse, CreateObjectRequest>(
      endpoints.crms.objectCreate(crmId),
      data,
    );
  },

  // Get object
  getObject: async (
    crmId: string,
    objectId: string,
  ): Promise<ObjectGetResponse> => {
    return crmsRequest.get<ObjectGetResponse>(
      endpoints.crms.object(crmId, objectId),
    );
  },

  // Update object
  updateObject: async (
    crmId: string,
    objectId: string,
    data: { parent?: string; class?: string },
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.objectUpdate(crmId, objectId),
      data,
    );
  },

  // Delete object
  deleteObject: async (
    crmId: string,
    objectId: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.objectDelete(crmId, objectId),
    );
  },

  // Move object (change status - for drag-drop)
  moveObject: async (
    crmId: string,
    objectId: string,
    data: MoveObjectRequest,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse, MoveObjectRequest>(
      endpoints.crms.objectMove(crmId, objectId),
      data,
    );
  },

  // Set multiple values
  setValues: async (
    crmId: string,
    objectId: string,
    values: Record<string, string>,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.valuesSet(crmId, objectId),
      values,
    );
  },

  // Set single value
  setValue: async (
    crmId: string,
    objectId: string,
    field: string,
    value: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.valueSet(crmId, objectId, field),
      { value },
    );
  },

  // ============= Link Methods =============

  // List links
  listLinks: async (
    crmId: string,
    objectId: string,
  ): Promise<LinkListResponse> => {
    return crmsRequest.get<LinkListResponse>(
      endpoints.crms.links(crmId, objectId),
    );
  },

  // Create link
  createLink: async (
    crmId: string,
    objectId: string,
    target: string,
    linktype: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.linkCreate(crmId, objectId),
      { target, linktype },
    );
  },

  // Delete link
  deleteLink: async (
    crmId: string,
    objectId: string,
    target: string,
    linktype: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.linkDelete(crmId, objectId),
      { target, linktype },
    );
  },

  // ============= Comment Methods =============

  // List comments
  listComments: async (
    crmId: string,
    objectId: string,
  ): Promise<CommentListResponse> => {
    return crmsRequest.get<CommentListResponse>(
      endpoints.crms.comments(crmId, objectId),
    );
  },

  // Create comment
  createComment: async (
    crmId: string,
    objectId: string,
    content: string,
    parent?: string,
    files?: File[],
  ): Promise<{ data: Comment }> => {
    const formData = new FormData();
    formData.append("content", content);
    if (parent) formData.append("parent", parent);
    if (files) {
      files.forEach((file) => formData.append("files", file));
    }
    return crmsRequest.post<{ data: Comment }>(
      endpoints.crms.commentCreate(crmId, objectId),
      formData,
    );
  },

  // Update comment
  updateComment: async (
    crmId: string,
    objectId: string,
    commentId: string,
    content: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.commentUpdate(crmId, objectId, commentId),
      { content },
    );
  },

  // Delete comment
  deleteComment: async (
    crmId: string,
    objectId: string,
    commentId: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.commentDelete(crmId, objectId, commentId),
    );
  },

  // ============= Activity Methods =============

  // List activity
  listActivity: async (
    crmId: string,
    objectId: string,
  ): Promise<ActivityListResponse> => {
    return crmsRequest.get<ActivityListResponse>(
      endpoints.crms.activity(crmId, objectId),
    );
  },

  // ============= Attachment Methods =============

  // Upload attachments
  uploadAttachments: async (
    crmId: string,
    objectId: string,
    files: File[],
  ): Promise<AttachmentListResponse> => {
    const formData = new FormData();
    for (const file of files) {
      formData.append("files", file);
    }
    return crmsRequest.post(
      endpoints.crms.attachmentCreate(crmId, objectId),
      formData,
    );
  },

  // List attachments
  listAttachments: async (
    crmId: string,
    objectId: string,
  ): Promise<AttachmentListResponse> => {
    return crmsRequest.get<AttachmentListResponse>(
      endpoints.crms.attachments(crmId, objectId),
    );
  },

  // Delete attachment
  deleteAttachment: async (
    crmId: string,
    objectId: string,
    attachmentId: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.attachmentDelete(crmId, objectId, attachmentId),
    );
  },

  // ============= Watcher Methods =============

  // List watchers
  listWatchers: async (
    crmId: string,
    objectId: string,
  ): Promise<WatcherListResponse> => {
    return crmsRequest.get<WatcherListResponse>(
      endpoints.crms.watchers(crmId, objectId),
    );
  },

  // Add watcher (self)
  addWatcher: async (
    crmId: string,
    objectId: string,
  ): Promise<SuccessResponse & { data: { watching: boolean } }> => {
    return crmsRequest.post<
      SuccessResponse & { data: { watching: boolean } }
    >(endpoints.crms.watcherAdd(crmId, objectId));
  },

  // Remove watcher (self)
  removeWatcher: async (
    crmId: string,
    objectId: string,
  ): Promise<SuccessResponse & { data: { watching: boolean } }> => {
    return crmsRequest.post<
      SuccessResponse & { data: { watching: boolean } }
    >(endpoints.crms.watcherRemove(crmId, objectId));
  },

  // ============= Design Import/Export Methods =============

  // Export design as template JSON
  exportDesign: async (
    crmId: string,
  ): Promise<{ data: Record<string, unknown> }> => {
    return crmsRequest.get(endpoints.crms.designExport(crmId));
  },

  // Import design from template JSON or built-in template ID
  importDesign: async (
    crmId: string,
    data: Record<string, unknown>,
    template?: string,
    templateVersion?: number,
  ): Promise<SuccessResponse> => {
    const payload: Record<string, string> = {
      template: template || "",
      template_version: String(templateVersion || 0),
    };
    // Only send data if it has content (for file imports)
    // For built-in templates, the backend loads the template file by template ID
    if (Object.keys(data).length > 0) {
      payload.data = JSON.stringify(data);
    }
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.designImport(crmId),
      payload,
    );
  },

  // ============= View Methods =============

  // List views
  listViews: async (crmId: string): Promise<ViewListResponse> => {
    return crmsRequest.get<ViewListResponse>(
      endpoints.crms.views(crmId),
    );
  },

  // Create view
  createView: async (
    crmId: string,
    data: CreateViewRequest,
  ): Promise<ViewCreateResponse> => {
    return crmsRequest.post<ViewCreateResponse, CreateViewRequest>(
      endpoints.crms.viewCreate(crmId),
      data,
    );
  },

  // Update view
  updateView: async (
    crmId: string,
    viewId: string,
    data: UpdateViewRequest,
  ): Promise<SuccessResponse> => {
    // Filter out undefined values before sending
    const cleanData: Record<string, string> = {};
    for (const [key, value] of Object.entries(data)) {
      if (value !== undefined && value !== null) {
        cleanData[key] = value;
      }
    }
    return crmsRequest.post<SuccessResponse, Record<string, string>>(
      endpoints.crms.viewUpdate(crmId, viewId),
      cleanData,
    );
  },

  // Delete view
  deleteView: async (
    crmId: string,
    viewId: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.viewDelete(crmId, viewId),
    );
  },

  // Reorder views
  reorderViews: async (
    crmId: string,
    order: string[],
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.viewReorder(crmId),
      { order: order.join(",") },
    );
  },

  // ============= Class Methods =============

  // List classes
  listClasses: async (crmId: string): Promise<ClassListResponse> => {
    return crmsRequest.get<ClassListResponse>(
      endpoints.crms.classes(crmId),
    );
  },

  // Create class
  createClass: async (
    crmId: string,
    data: CreateClassRequest,
  ): Promise<ClassCreateResponse> => {
    return crmsRequest.post<ClassCreateResponse, CreateClassRequest>(
      endpoints.crms.classCreate(crmId),
      data,
    );
  },

  // Update class
  updateClass: async (
    crmId: string,
    classId: string,
    data: UpdateClassRequest,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse, UpdateClassRequest>(
      endpoints.crms.classUpdate(crmId, classId),
      data,
    );
  },

  // Delete class
  deleteClass: async (
    crmId: string,
    classId: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.classDelete(crmId, classId),
    );
  },

  // ============= Hierarchy Methods =============

  // Get hierarchy
  getHierarchy: async (
    crmId: string,
    classId: string,
  ): Promise<HierarchyGetResponse> => {
    return crmsRequest.get<HierarchyGetResponse>(
      endpoints.crms.hierarchy(crmId, classId),
    );
  },

  // Set hierarchy
  setHierarchy: async (
    crmId: string,
    classId: string,
    parents: string[],
  ): Promise<SuccessResponse> => {
    // Use _none_ to indicate empty list, since empty string means "can be root"
    const parentsStr = parents.length === 0 ? "_none_" : parents.join(",");
    return crmsRequest.post<SuccessResponse, SetHierarchyRequest>(
      endpoints.crms.hierarchySet(crmId, classId),
      { parents: parentsStr },
    );
  },

  // ============= Field Methods =============

  // List fields
  listFields: async (
    crmId: string,
    classId: string,
  ): Promise<FieldListResponse> => {
    return crmsRequest.get<FieldListResponse>(
      endpoints.crms.fields(crmId, classId),
    );
  },

  // Create field
  createField: async (
    crmId: string,
    classId: string,
    data: CreateFieldRequest,
  ): Promise<FieldCreateResponse> => {
    return crmsRequest.post<FieldCreateResponse, CreateFieldRequest>(
      endpoints.crms.fieldCreate(crmId, classId),
      data,
    );
  },

  // Update field
  updateField: async (
    crmId: string,
    classId: string,
    fieldId: string,
    data: UpdateFieldRequest,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse, UpdateFieldRequest>(
      endpoints.crms.fieldUpdate(crmId, classId, fieldId),
      data,
    );
  },

  // Delete field
  deleteField: async (
    crmId: string,
    classId: string,
    fieldId: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.fieldDelete(crmId, classId, fieldId),
    );
  },

  // Reorder fields
  reorderFields: async (
    crmId: string,
    classId: string,
    order: string[],
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.fieldReorder(crmId, classId),
      { order: order.join(",") },
    );
  },

  // ============= Option Methods =============

  // List options
  listOptions: async (
    crmId: string,
    classId: string,
    fieldId: string,
  ): Promise<OptionListResponse> => {
    return crmsRequest.get<OptionListResponse>(
      endpoints.crms.options(crmId, classId, fieldId),
    );
  },

  // Create option
  createOption: async (
    crmId: string,
    classId: string,
    fieldId: string,
    data: CreateOptionRequest,
  ): Promise<OptionCreateResponse> => {
    return crmsRequest.post<OptionCreateResponse, CreateOptionRequest>(
      endpoints.crms.optionCreate(crmId, classId, fieldId),
      data,
    );
  },

  // Update option
  updateOption: async (
    crmId: string,
    classId: string,
    fieldId: string,
    optionId: string,
    data: UpdateOptionRequest,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse, UpdateOptionRequest>(
      endpoints.crms.optionUpdate(crmId, classId, fieldId, optionId),
      data,
    );
  },

  // Delete option
  deleteOption: async (
    crmId: string,
    classId: string,
    fieldId: string,
    optionId: string,
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.optionDelete(crmId, classId, fieldId, optionId),
    );
  },

  // Reorder options
  reorderOptions: async (
    crmId: string,
    classId: string,
    fieldId: string,
    order: string[],
  ): Promise<SuccessResponse> => {
    return crmsRequest.post<SuccessResponse>(
      endpoints.crms.optionReorder(crmId, classId, fieldId),
      { order: order.join(",") },
    );
  },

  // ============================================================================
  // Remote CRMs (Subscribe/Bookmark)
  // ============================================================================

  // Probe a remote crm by URL
  probe: async (
    url: string,
  ): Promise<{
    data: {
      id: string;
      name: string;
      description: string;
      prefix: string;
      fingerprint: string;
      class: string;
      server: string;
      remote: boolean;
    };
  }> => {
    return crmsRequest.post(endpoints.crms.probe, { url });
  },

  // Get recommended crms
  recommendations: async (): Promise<{
    data: {
      crms: Array<{
        id: string;
        name: string;
        blurb: string;
        fingerprint: string;
      }>;
    };
  }> => {
    return crmsRequest.get(endpoints.crms.recommendations);
  },

  // Subscribe to a remote crm
  subscribe: async (
    crmId: string,
    server?: string,
  ): Promise<{ data: { fingerprint: string } }> => {
    return crmsRequest.post(endpoints.crms.subscribe, {
      crm: crmId,
      server,
    });
  },

  // Unsubscribe from a remote crm
  unsubscribe: async (
    crmId: string,
  ): Promise<{ data: { success: boolean } }> => {
    return crmsRequest.post(endpoints.crms.unsubscribe, {
      crm: crmId,
    });
  },

  // ============================================================================
  // Access Control
  // ============================================================================

  // Get access rules for a crm
  getAccessRules: async (
    crmId: string,
  ): Promise<{
    data: {
      rules: AccessRule[];
      owner: { id: string; name: string };
    };
  }> => {
    return crmsRequest.get(endpoints.crms.access(crmId));
  },

  // Set access level for a subject
  setAccessLevel: async (
    crmId: string,
    subject: string,
    level: string,
  ): Promise<{ data: { success: boolean } }> => {
    return crmsRequest.post(endpoints.crms.accessSet(crmId), {
      subject,
      level,
    });
  },

  // Revoke access for a subject
  revokeAccess: async (
    crmId: string,
    subject: string,
  ): Promise<{ data: { success: boolean } }> => {
    return crmsRequest.post(endpoints.crms.accessRevoke(crmId), {
      subject,
    });
  },

  // ============= Notification Methods =============

  // Check if notification subscriptions exist
  checkSubscription: async (): Promise<{ data: { exists: boolean } }> => {
    return crmsRequest.get(endpoints.crms.notificationsCheck);
  },

  // Search users (for adding access rules)
  searchUsers: async (
    query: string,
  ): Promise<{ results: { id: string; name: string; fingerprint: string }[] }> => {
    return crmsRequest.get(`-/users/search?q=${encodeURIComponent(query)}`);
  },

  // List groups (for adding access rules)
  listGroups: async (): Promise<{ groups: { id: string; name: string }[] }> => {
    return crmsRequest.get("-/groups");
  },
};

export default crmsApi;
