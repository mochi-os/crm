// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

// App CI never typechecks (lint is eslint only; tsc runs inside build), so a
// renamed or dropped library export would reach main uncaught. Each block
// checks the binding is defined AND is the library's object: `toBe` alone
// passes when both sides are undefined.
import { describe, expect, it } from "vitest";
import * as lib from "@mochi/web";
import { crmsRequest } from "@/api/request";
import { AddFieldDialog } from "@/features/editor/components/add-dialogs";
import { OptionDialog } from "@/features/editor/components/option-dialog";

describe("bindings onto @mochi/web", () => {
  it("builds this app's request client with the shared factory", () => {
    expect(lib.createAppClient).toBeInstanceOf(Function);
    expect(crmsRequest).toBeDefined();
    expect(crmsRequest.get).toBeInstanceOf(Function);
    expect(crmsRequest.post).toBeInstanceOf(Function);
    // The factory's whole surface, so a hand-rolled object here, or a method
    // the library stops handing out, would not pass as one.
    expect(Object.keys(crmsRequest).sort()).toEqual(
      Object.keys(lib.createAppClient({ appName: "crm" })).sort(),
    );
  });

  it("takes the field dialog from the library", () => {
    expect(AddFieldDialog).toBeDefined();
    expect(AddFieldDialog).toBe(lib.AddFieldDialog);
  });

  it("takes the option dialog from the library, under this app's name", () => {
    expect(OptionDialog).toBeDefined();
    expect(OptionDialog).toBe(lib.EntityOptionDialog);
  });
});
