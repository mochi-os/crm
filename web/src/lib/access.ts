import type { CrmAccess } from "@/types";

export const canDesign = (a: CrmAccess) => a === "owner" || a === "design";
export const canCreate = (a: CrmAccess) => canDesign(a);
export const canWrite = (a: CrmAccess) => canCreate(a) || a === "write";
export const canComment = (a: CrmAccess) => canWrite(a) || a === "comment";
