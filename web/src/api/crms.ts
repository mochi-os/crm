// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// The CRM API is the shared entity API with nothing added: every route this app
// calls is one the projects app calls too. Only the response nouns differ, and
// those arrive through the shape bundle below.

import { createEntityApi, type EntityApiShapes } from "@mochi/web";
import endpoints from "./endpoints";
import { crmsRequest } from "./request";
import type { Crm, CrmDetails, CrmObject, ObjectLink } from "@/types";

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

interface CrmApiShapes extends EntityApiShapes {
  summary: Crm;
  details: CrmDetails;
  object: CrmObject;
  objectDetail: {
    object: CrmObject;
    values: Record<string, string>;
    outgoing: ObjectLink[];
    incoming: ObjectLink[];
    watching: boolean;
    comment_count: number;
  };
  objectCreated: { id: string };
  createRequest: CreateCrmRequest;
  updateRequest: UpdateCrmRequest;
  listKey: "crms";
}

const crmsApi = createEntityApi<CrmApiShapes>({
  request: crmsRequest,
  endpoints: endpoints.crms,
  resourceKey: "crm",
});

export default crmsApi;
