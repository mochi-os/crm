// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.

/* eslint-disable lingui/no-unlocalized-strings */
// App CI never typechecks (lint is eslint only; tsc runs inside build), so a
// renamed or dropped library export would reach main uncaught. Each block
// checks the binding is defined AND is the library's object: `toBe` alone
// passes when both sides are undefined.
import { describe, expect, it } from "vitest";
import * as lib from "@mochi/web";
import { crmsRequest } from "@/api/request";
import { AddFieldDialog } from "@/features/editor/components/add-dialogs";
import { OptionDialog } from "@/features/editor/components/option-dialog";
import { FilterBar } from "@/features/views/components/filter-bar";
import { canComment, canCreate, canDesign, canWrite } from "@/lib/access";
import { rankBetween, rankCompare } from "@/lib/rank";

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

  it("takes the filter bar from the library", () => {
    expect(FilterBar).toBeDefined();
    expect(FilterBar).toBe(lib.FilterBar);
  });

  it("takes all four permission checks from the library", () => {
    expect(canComment).toBeDefined();
    expect(canCreate).toBeDefined();
    expect(canDesign).toBeDefined();
    expect(canWrite).toBeDefined();
    expect(canComment).toBe(lib.canComment);
    expect(canCreate).toBe(lib.canCreate);
    expect(canDesign).toBe(lib.canDesign);
    expect(canWrite).toBe(lib.canWrite);
  });

  it("takes both rank helpers from the library", () => {
    expect(rankBetween).toBeDefined();
    expect(rankCompare).toBeDefined();
    expect(rankBetween).toBe(lib.rankBetween);
    expect(rankCompare).toBe(lib.rankCompare);
  });
});
