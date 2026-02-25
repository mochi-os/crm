// Tests for API endpoint URL generation
import { describe, it, expect } from "vitest";
import endpoints from "./endpoints";

describe("endpoints.crms", () => {
  describe("class-level endpoints (static strings)", () => {
    it("should have list endpoint", () => {
      expect(endpoints.crms.list).toBe("-/list");
    });

    it("should have create endpoint", () => {
      expect(endpoints.crms.create).toBe("-/create");
    });

  });

  describe("entity-level crm endpoints", () => {
    it("should generate info endpoint with crm ID", () => {
      expect(endpoints.crms.info("abc123")).toBe("abc123/-/info");
    });

    it("should generate update endpoint with crm ID", () => {
      expect(endpoints.crms.update("abc123")).toBe("abc123/-/update");
    });

    it("should generate delete endpoint with crm ID", () => {
      expect(endpoints.crms.delete("abc123")).toBe("abc123/-/delete");
    });
  });

  describe("object endpoints", () => {
    it("should generate objects list endpoint", () => {
      expect(endpoints.crms.objects("proj1")).toBe("proj1/-/objects");
    });

    it("should generate object create endpoint", () => {
      expect(endpoints.crms.objectCreate("proj1")).toBe(
        "proj1/-/objects/create",
      );
    });

    it("should generate object get endpoint", () => {
      expect(endpoints.crms.object("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1",
      );
    });

    it("should generate object update endpoint", () => {
      expect(endpoints.crms.objectUpdate("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/update",
      );
    });

    it("should generate object delete endpoint", () => {
      expect(endpoints.crms.objectDelete("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/delete",
      );
    });

    it("should generate object move endpoint", () => {
      expect(endpoints.crms.objectMove("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/move",
      );
    });
  });

  describe("value endpoints", () => {
    it("should generate values set endpoint", () => {
      expect(endpoints.crms.valuesSet("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/values",
      );
    });

    it("should generate single value set endpoint", () => {
      expect(endpoints.crms.valueSet("proj1", "obj1", "status")).toBe(
        "proj1/-/objects/obj1/values/status",
      );
    });
  });

  describe("view endpoints", () => {
    it("should generate views list endpoint", () => {
      expect(endpoints.crms.views("proj1")).toBe("proj1/-/views");
    });

    it("should generate view create endpoint", () => {
      expect(endpoints.crms.viewCreate("proj1")).toBe(
        "proj1/-/views/create",
      );
    });

    it("should generate view update endpoint", () => {
      expect(endpoints.crms.viewUpdate("proj1", "view1")).toBe(
        "proj1/-/views/view1/update",
      );
    });

    it("should generate view delete endpoint", () => {
      expect(endpoints.crms.viewDelete("proj1", "view1")).toBe(
        "proj1/-/views/view1/delete",
      );
    });
  });

  describe("class endpoints", () => {
    it("should generate classes list endpoint", () => {
      expect(endpoints.crms.classes("proj1")).toBe("proj1/-/classes");
    });

    it("should generate class create endpoint", () => {
      expect(endpoints.crms.classCreate("proj1")).toBe(
        "proj1/-/classes/create",
      );
    });

    it("should generate class update endpoint", () => {
      expect(endpoints.crms.classUpdate("proj1", "task")).toBe(
        "proj1/-/classes/task/update",
      );
    });

    it("should generate class delete endpoint", () => {
      expect(endpoints.crms.classDelete("proj1", "task")).toBe(
        "proj1/-/classes/task/delete",
      );
    });
  });

  describe("field endpoints", () => {
    it("should generate fields list endpoint", () => {
      expect(endpoints.crms.fields("proj1", "task")).toBe(
        "proj1/-/classes/task/fields",
      );
    });

    it("should generate field create endpoint", () => {
      expect(endpoints.crms.fieldCreate("proj1", "task")).toBe(
        "proj1/-/classes/task/fields/create",
      );
    });

    it("should generate field reorder endpoint", () => {
      expect(endpoints.crms.fieldReorder("proj1", "task")).toBe(
        "proj1/-/classes/task/fields/reorder",
      );
    });

    it("should generate field update endpoint", () => {
      expect(endpoints.crms.fieldUpdate("proj1", "task", "field1")).toBe(
        "proj1/-/classes/task/fields/field1/update",
      );
    });

    it("should generate field delete endpoint", () => {
      expect(endpoints.crms.fieldDelete("proj1", "task", "field1")).toBe(
        "proj1/-/classes/task/fields/field1/delete",
      );
    });
  });

  describe("option endpoints", () => {
    it("should generate options list endpoint", () => {
      expect(endpoints.crms.options("proj1", "task", "status")).toBe(
        "proj1/-/classes/task/fields/status/options",
      );
    });

    it("should generate option create endpoint", () => {
      expect(endpoints.crms.optionCreate("proj1", "task", "status")).toBe(
        "proj1/-/classes/task/fields/status/options/create",
      );
    });

    it("should generate option update endpoint", () => {
      expect(
        endpoints.crms.optionUpdate("proj1", "task", "status", "opt1"),
      ).toBe("proj1/-/classes/task/fields/status/options/opt1/update");
    });

    it("should generate option delete endpoint", () => {
      expect(
        endpoints.crms.optionDelete("proj1", "task", "status", "opt1"),
      ).toBe("proj1/-/classes/task/fields/status/options/opt1/delete");
    });
  });

  describe("comment endpoints", () => {
    it("should generate comments list endpoint", () => {
      expect(endpoints.crms.comments("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/comments",
      );
    });

    it("should generate comment create endpoint", () => {
      expect(endpoints.crms.commentCreate("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/comments/create",
      );
    });

    it("should generate comment update endpoint", () => {
      expect(endpoints.crms.commentUpdate("proj1", "obj1", "comment1")).toBe(
        "proj1/-/objects/obj1/comments/comment1/update",
      );
    });

    it("should generate comment delete endpoint", () => {
      expect(endpoints.crms.commentDelete("proj1", "obj1", "comment1")).toBe(
        "proj1/-/objects/obj1/comments/comment1/delete",
      );
    });
  });

  describe("watcher endpoints", () => {
    it("should generate watchers list endpoint", () => {
      expect(endpoints.crms.watchers("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/watchers",
      );
    });

    it("should generate watcher add endpoint", () => {
      expect(endpoints.crms.watcherAdd("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/watchers/add",
      );
    });

    it("should generate watcher remove endpoint", () => {
      expect(endpoints.crms.watcherRemove("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/watchers/remove",
      );
    });
  });

  describe("activity endpoint", () => {
    it("should generate activity endpoint", () => {
      expect(endpoints.crms.activity("proj1", "obj1")).toBe(
        "proj1/-/objects/obj1/activity",
      );
    });
  });
});
