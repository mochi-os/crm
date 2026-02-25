import type { CrmAccess } from "@/types";

export const canDesign = (a: CrmAccess) => a === "owner" || a === "design";
export const canWrite = (a: CrmAccess) => canDesign(a) || a === "write";
export const canComment = (a: CrmAccess) => canWrite(a) || a === "comment";
