// Endpoints are relative to baseURL which is already set to /crm/ in request.ts
const endpoints = {
  crms: {
    // Class-level endpoints (no entity context)
    list: "-/list",
    create: "-/create",
    search: "-/directory/search",
    probe: "-/probe",
    recommendations: "-/recommendations",
    subscribe: "-/subscribe",
    unsubscribe: "-/unsubscribe",

    // Entity-level endpoints (use /-/ separator)
    info: (crmId: string) => `${crmId}/-/info`,
    update: (crmId: string) => `${crmId}/-/update`,
    delete: (crmId: string) => `${crmId}/-/delete`,
    people: (crmId: string) => `${crmId}/-/people`,

    // Access control endpoints
    access: (crmId: string) => `${crmId}/-/access`,
    accessSet: (crmId: string) => `${crmId}/-/access/set`,
    accessRevoke: (crmId: string) => `${crmId}/-/access/revoke`,

    // Object endpoints
    objects: (crmId: string) => `${crmId}/-/objects`,
    objectCreate: (crmId: string) => `${crmId}/-/objects/create`,
    object: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}`,
    objectUpdate: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/update`,
    objectDelete: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/delete`,
    objectMove: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/move`,

    // Value endpoints
    valuesSet: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/values`,
    valueSet: (crmId: string, objectId: string, field: string) =>
      `${crmId}/-/objects/${objectId}/values/${field}`,

    // Link endpoints
    links: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/links`,
    linkCreate: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/links/create`,
    linkDelete: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/links/delete`,

    // Comment endpoints
    comments: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/comments`,
    commentCreate: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/comments/create`,
    commentUpdate: (crmId: string, objectId: string, commentId: string) =>
      `${crmId}/-/objects/${objectId}/comments/${commentId}/update`,
    commentDelete: (crmId: string, objectId: string, commentId: string) =>
      `${crmId}/-/objects/${objectId}/comments/${commentId}/delete`,

    // Attachment endpoints
    attachments: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/attachments`,
    attachmentCreate: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/attachments/create`,
    attachmentDelete: (
      crmId: string,
      objectId: string,
      attachmentId: string,
    ) =>
      `${crmId}/-/objects/${objectId}/attachments/${attachmentId}/delete`,

    // Activity endpoint
    activity: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/activity`,

    // Watcher endpoints
    watchers: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/watchers`,
    watcherAdd: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/watchers/add`,
    watcherRemove: (crmId: string, objectId: string) =>
      `${crmId}/-/objects/${objectId}/watchers/remove`,

    // Design import/export endpoints
    designExport: (crmId: string) => `${crmId}/-/design/export`,
    designImport: (crmId: string) => `${crmId}/-/design/import`,

    // View endpoints
    views: (crmId: string) => `${crmId}/-/views`,
    viewCreate: (crmId: string) => `${crmId}/-/views/create`,
    viewReorder: (crmId: string) => `${crmId}/-/views/reorder`,
    viewUpdate: (crmId: string, viewId: string) =>
      `${crmId}/-/views/${viewId}/update`,
    viewDelete: (crmId: string, viewId: string) =>
      `${crmId}/-/views/${viewId}/delete`,

    // Class endpoints
    classes: (crmId: string) => `${crmId}/-/classes`,
    classCreate: (crmId: string) => `${crmId}/-/classes/create`,
    classUpdate: (crmId: string, classId: string) =>
      `${crmId}/-/classes/${classId}/update`,
    classDelete: (crmId: string, classId: string) =>
      `${crmId}/-/classes/${classId}/delete`,

    // Hierarchy endpoints
    hierarchy: (crmId: string, classId: string) =>
      `${crmId}/-/classes/${classId}/hierarchy`,
    hierarchySet: (crmId: string, classId: string) =>
      `${crmId}/-/classes/${classId}/hierarchy/set`,

    // Field endpoints
    fields: (crmId: string, classId: string) =>
      `${crmId}/-/classes/${classId}/fields`,
    fieldCreate: (crmId: string, classId: string) =>
      `${crmId}/-/classes/${classId}/fields/create`,
    fieldReorder: (crmId: string, classId: string) =>
      `${crmId}/-/classes/${classId}/fields/reorder`,
    fieldUpdate: (crmId: string, classId: string, fieldId: string) =>
      `${crmId}/-/classes/${classId}/fields/${fieldId}/update`,
    fieldDelete: (crmId: string, classId: string, fieldId: string) =>
      `${crmId}/-/classes/${classId}/fields/${fieldId}/delete`,

    // Option endpoints
    options: (crmId: string, classId: string, fieldId: string) =>
      `${crmId}/-/classes/${classId}/fields/${fieldId}/options`,
    optionCreate: (crmId: string, classId: string, fieldId: string) =>
      `${crmId}/-/classes/${classId}/fields/${fieldId}/options/create`,
    optionReorder: (crmId: string, classId: string, fieldId: string) =>
      `${crmId}/-/classes/${classId}/fields/${fieldId}/options/reorder`,
    optionUpdate: (
      crmId: string,
      classId: string,
      fieldId: string,
      optionId: string,
    ) =>
      `${crmId}/-/classes/${classId}/fields/${fieldId}/options/${optionId}/update`,
    optionDelete: (
      crmId: string,
      classId: string,
      fieldId: string,
      optionId: string,
    ) =>
      `${crmId}/-/classes/${classId}/fields/${fieldId}/options/${optionId}/delete`,

    // Notification endpoints
    notificationsCheck: "-/notifications/check",
  },
} as const;

export type Endpoints = typeof endpoints;

export default endpoints;
