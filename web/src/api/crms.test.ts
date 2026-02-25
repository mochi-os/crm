// Comprehensive tests for the CRMs API
import { describe, it, expect, vi, beforeEach } from "vitest";
import crmsApi from "./crms";
import { crmsRequest } from "./request";

// Mock the request module
vi.mock("./request", () => ({
  crmsRequest: {
    get: vi.fn(),
    post: vi.fn(),
  },
}));

describe("crmsApi", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  // ============= Crm Methods =============

  describe("list", () => {
    it("should fetch crms list", async () => {
      const mockResponse = {
        data: {
          crms: [
            { id: "1", fingerprint: "abc", name: "Crm 1" },
            { id: "2", fingerprint: "def", name: "Crm 2" },
          ],
        },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.list();

      expect(crmsRequest.get).toHaveBeenCalledWith("-/list");
      expect(result).toEqual(mockResponse);
    });
  });

  describe("create", () => {
    it("should create a new crm", async () => {
      const mockResponse = {
        data: { id: "123", fingerprint: "abc123" },
      };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      const result = await crmsApi.create({
        name: "New CRM",
        privacy: "private",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith("-/create", {
        name: "New CRM",
        privacy: "private",
      });
      expect(result).toEqual(mockResponse);
    });

    it("should create crm with optional fields", async () => {
      const mockResponse = { data: { id: "123", fingerprint: "abc123" } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.create({
        name: "New CRM",
        description: "A test CRM",
        prefix: "TEST",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith("-/create", {
        name: "New CRM",
        description: "A test CRM",
        prefix: "TEST",
      });
    });
  });

  describe("get", () => {
    it("should fetch crm details", async () => {
      const mockResponse = {
        data: {
          crm: { id: "1", name: "Test Crm" },
          classes: [],
          fields: {},
          options: {},
          views: [],
          hierarchy: {},
        },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.get("proj123");

      expect(crmsRequest.get).toHaveBeenCalledWith("proj123/-/info");
      expect(result).toEqual(mockResponse);
    });
  });

  describe("update", () => {
    it("should update crm", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      const result = await crmsApi.update("proj123", {
        name: "Updated Name",
        description: "New description",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith("proj123/-/update", {
        name: "Updated Name",
        description: "New description",
      });
      expect(result).toEqual(mockResponse);
    });
  });

  describe("delete", () => {
    it("should delete crm", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      const result = await crmsApi.delete("proj123");

      expect(crmsRequest.post).toHaveBeenCalledWith("proj123/-/delete");
      expect(result).toEqual(mockResponse);
    });
  });

  // ============= Object Methods =============

  describe("listObjects", () => {
    it("should fetch objects without params", async () => {
      const mockResponse = { data: { objects: [] } };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      await crmsApi.listObjects("proj123");

      expect(crmsRequest.get).toHaveBeenCalledWith("proj123/-/objects");
    });

    it("should fetch objects with class filter", async () => {
      const mockResponse = { data: { objects: [] } };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      await crmsApi.listObjects("proj123", { class: "task" });

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects?class=task",
      );
    });

    it("should fetch objects with multiple filters", async () => {
      const mockResponse = { data: { objects: [] } };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      await crmsApi.listObjects("proj123", {
        class: "task",
        status: "in_progress",
      });

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects?class=task&status=in_progress",
      );
    });

    it("should handle empty parent filter", async () => {
      const mockResponse = { data: { objects: [] } };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      await crmsApi.listObjects("proj123", { parent: "" });

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects?parent=",
      );
    });
  });

  describe("createObject", () => {
    it("should create an object", async () => {
      const mockResponse = {
        data: { id: "obj1", number: 1, readable: "proj-1" },
      };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      const result = await crmsApi.createObject("proj123", {
        class: "task",
        title: "New Task",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/create",
        { class: "task", title: "New Task" },
      );
      expect(result).toEqual(mockResponse);
    });

    it("should create object with parent", async () => {
      const mockResponse = { data: { id: "obj2", number: 2 } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.createObject("proj123", {
        class: "subtask",
        parent: "obj1",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/create",
        { class: "subtask", parent: "obj1" },
      );
    });
  });

  describe("getObject", () => {
    it("should fetch object details", async () => {
      const mockResponse = {
        data: {
          object: { id: "obj1", class: "task" },
          values: { title: "Test Task" },
          watching: false,
        },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.getObject("proj123", "obj1");

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects/obj1",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe("updateObject", () => {
    it("should update object", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.updateObject("proj123", "obj1", { class: "bug" });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/update",
        { class: "bug" },
      );
    });
  });

  describe("deleteObject", () => {
    it("should delete object", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.deleteObject("proj123", "obj1");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/delete",
      );
    });
  });

  describe("moveObject", () => {
    it("should move object to new column value", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.moveObject("proj123", "obj1", { field: "status", value: "done" });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/move",
        { field: "status", value: "done" },
      );
    });
  });

  describe("setValues", () => {
    it("should set multiple values at once", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.setValues("proj123", "obj1", {
        title: "Updated Title",
        priority: "high",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/values",
        { title: "Updated Title", priority: "high" },
      );
    });
  });

  describe("setValue", () => {
    it("should set a single field value", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.setValue("proj123", "obj1", "status", "in_progress");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/values/status",
        { value: "in_progress" },
      );
    });
  });

  // ============= Comment Methods =============

  describe("listComments", () => {
    it("should fetch comments for an object", async () => {
      const mockResponse = {
        data: {
          comments: [
            { id: "c1", content: "First comment", author: "user1" },
          ],
        },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listComments("proj123", "obj1");

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/comments",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe("createComment", () => {
    it("should create a comment", async () => {
      const mockResponse = {
        data: { id: "c1", content: "New comment", author: "user1" },
      };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.createComment("proj123", "obj1", "New comment");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/comments/create",
        expect.any(FormData),
      );
    });

    it("should create a reply comment", async () => {
      const mockResponse = { data: { id: "c2" } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.createComment("proj123", "obj1", "Reply", "c1");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/comments/create",
        expect.any(FormData),
      );
    });
  });

  describe("updateComment", () => {
    it("should update a comment", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.updateComment(
        "proj123",
        "obj1",
        "c1",
        "Updated content",
      );

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/comments/c1/update",
        { content: "Updated content" },
      );
    });
  });

  describe("deleteComment", () => {
    it("should delete a comment", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.deleteComment("proj123", "obj1", "c1");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/comments/c1/delete",
      );
    });
  });

  // ============= View Methods =============

  describe("listViews", () => {
    it("should fetch crm views", async () => {
      const mockResponse = {
        data: {
          views: [{ id: "v1", name: "Board", viewtype: "board" }],
        },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listViews("proj123");

      expect(crmsRequest.get).toHaveBeenCalledWith("proj123/-/views");
      expect(result).toEqual(mockResponse);
    });
  });

  describe("createView", () => {
    it("should create a view", async () => {
      const mockResponse = {
        data: { id: "v2", name: "List View", viewtype: "list" },
      };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.createView("proj123", {
        name: "List View",
        viewtype: "list",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/views/create",
        { name: "List View", viewtype: "list" },
      );
    });
  });

  describe("updateView", () => {
    it("should update a view", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.updateView("proj123", "v1", {
        name: "Updated Board",
        sort: "priority",
        direction: "desc",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/views/v1/update",
        { name: "Updated Board", sort: "priority", direction: "desc" },
      );
    });
  });

  describe("deleteView", () => {
    it("should delete a view", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.deleteView("proj123", "v1");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/views/v1/delete",
      );
    });
  });

  // ============= Class Methods =============

  describe("listClasses", () => {
    it("should fetch crm classes", async () => {
      const mockResponse = {
        data: { classes: [{ id: "task", name: "Task", sort: 0 }] },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listClasses("proj123");

      expect(crmsRequest.get).toHaveBeenCalledWith("proj123/-/classes");
      expect(result).toEqual(mockResponse);
    });
  });

  describe("createClass", () => {
    it("should create a class", async () => {
      const mockResponse = { data: { id: "bug", name: "Bug", sort: 1 } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.createClass("proj123", { name: "Bug" });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/create",
        { name: "Bug" },
      );
    });
  });

  describe("updateClass", () => {
    it("should update a class", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.updateClass("proj123", "task", { name: "Issue" });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/update",
        { name: "Issue" },
      );
    });
  });

  describe("deleteClass", () => {
    it("should delete a class", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.deleteClass("proj123", "bug");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/bug/delete",
      );
    });
  });

  // ============= Field Methods =============

  describe("listFields", () => {
    it("should fetch fields for a class", async () => {
      const mockResponse = {
        data: {
          fields: [{ id: "title", name: "Title", fieldtype: "text" }],
        },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listFields("proj123", "task");

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe("createField", () => {
    it("should create a field", async () => {
      const mockResponse = {
        data: { id: "priority", name: "Priority", fieldtype: "select", sort: 3 },
      };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.createField("proj123", "task", {
        name: "Priority",
        fieldtype: "select",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/create",
        { name: "Priority", fieldtype: "select" },
      );
    });
  });

  describe("updateField", () => {
    it("should update a field", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.updateField("proj123", "task", "priority", {
        flags: "required",
        position: "card",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/priority/update",
        { flags: "required", position: "card" },
      );
    });
  });

  describe("deleteField", () => {
    it("should delete a field", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.deleteField("proj123", "task", "priority");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/priority/delete",
      );
    });
  });

  describe("reorderFields", () => {
    it("should reorder fields", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.reorderFields("proj123", "task", [
        "title",
        "status",
        "priority",
      ]);

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/reorder",
        { order: "title,status,priority" },
      );
    });
  });

  // ============= Option Methods =============

  describe("listOptions", () => {
    it("should fetch options for a field", async () => {
      const mockResponse = {
        data: {
          options: [{ id: "high", name: "High", colour: "#ff0000" }],
        },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listOptions(
        "proj123",
        "task",
        "priority",
      );

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/priority/options",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe("createOption", () => {
    it("should create an option", async () => {
      const mockResponse = {
        data: { id: "critical", name: "Critical", colour: "#ff0000", sort: 0 },
      };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.createOption("proj123", "task", "priority", {
        name: "Critical",
        colour: "#ff0000",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/priority/options/create",
        { name: "Critical", colour: "#ff0000" },
      );
    });
  });

  describe("updateOption", () => {
    it("should update an option", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.updateOption("proj123", "task", "priority", "high", {
        colour: "#ff5500",
      });

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/priority/options/high/update",
        { colour: "#ff5500" },
      );
    });
  });

  describe("deleteOption", () => {
    it("should delete an option", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.deleteOption("proj123", "task", "priority", "low");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/priority/options/low/delete",
      );
    });
  });

  describe("reorderOptions", () => {
    it("should reorder options", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.reorderOptions("proj123", "task", "priority", [
        "critical",
        "high",
        "medium",
        "low",
      ]);

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/fields/priority/options/reorder",
        { order: "critical,high,medium,low" },
      );
    });
  });

  // ============= Watcher Methods =============

  describe("listWatchers", () => {
    it("should fetch watchers for an object", async () => {
      const mockResponse = {
        data: { watchers: [{ id: "user1", name: "User 1" }] },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listWatchers("proj123", "obj1");

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/watchers",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe("addWatcher", () => {
    it("should add current user as watcher", async () => {
      const mockResponse = { data: { success: true, watching: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      const result = await crmsApi.addWatcher("proj123", "obj1");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/watchers/add",
      );
      expect(result.data.watching).toBe(true);
    });
  });

  describe("removeWatcher", () => {
    it("should remove current user as watcher", async () => {
      const mockResponse = { data: { success: true, watching: false } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      const result = await crmsApi.removeWatcher("proj123", "obj1");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/watchers/remove",
      );
      expect(result.data.watching).toBe(false);
    });
  });

  // ============= Link Methods =============

  describe("listLinks", () => {
    it("should fetch links for an object", async () => {
      const mockResponse = {
        data: { links: [{ target: "obj2", linktype: "blocks" }] },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listLinks("proj123", "obj1");

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/links",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe("createLink", () => {
    it("should create a link between objects", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.createLink("proj123", "obj1", "obj2", "blocks");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/links/create",
        { target: "obj2", linktype: "blocks" },
      );
    });
  });

  describe("deleteLink", () => {
    it("should delete a link", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.deleteLink("proj123", "obj1", "obj2", "blocks");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/links/delete",
        { target: "obj2", linktype: "blocks" },
      );
    });
  });

  // ============= Hierarchy Methods =============

  describe("getHierarchy", () => {
    it("should fetch hierarchy for a class", async () => {
      const mockResponse = { data: { parents: ["epic", "story"] } };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.getHierarchy("proj123", "task");

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/classes/task/hierarchy",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe("setHierarchy", () => {
    it("should set hierarchy for a class", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.setHierarchy("proj123", "subtask", ["task", "bug"]);

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/subtask/hierarchy/set",
        { parents: "task,bug" },
      );
    });

    it("should handle empty hierarchy", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.setHierarchy("proj123", "task", []);

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/classes/task/hierarchy/set",
        { parents: "_none_" },
      );
    });
  });

  // ============= Activity Methods =============

  describe("listActivity", () => {
    it("should fetch activity for an object", async () => {
      const mockResponse = {
        data: {
          activities: [
            { id: "a1", action: "created", created: Date.now() },
          ],
        },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listActivity("proj123", "obj1");

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/activity",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  // ============= Attachment Methods =============

  describe("listAttachments", () => {
    it("should fetch attachments for an object", async () => {
      const mockResponse = {
        data: { attachments: [{ id: "att1", filename: "file.pdf" }] },
      };
      vi.mocked(crmsRequest.get).mockResolvedValue(mockResponse);

      const result = await crmsApi.listAttachments("proj123", "obj1");

      expect(crmsRequest.get).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/attachments",
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe("deleteAttachment", () => {
    it("should delete an attachment", async () => {
      const mockResponse = { data: { success: true } };
      vi.mocked(crmsRequest.post).mockResolvedValue(mockResponse);

      await crmsApi.deleteAttachment("proj123", "obj1", "att1");

      expect(crmsRequest.post).toHaveBeenCalledWith(
        "proj123/-/objects/obj1/attachments/att1/delete",
      );
    });
  });
});
