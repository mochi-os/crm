// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
// Not colocated under src/routes: the TanStack route generator has no
// routeFileIgnorePattern configured, so any file there becomes a route.
import { createElement, type ReactNode } from 'react'
import type { QueryClient } from '@tanstack/react-query'
import { renderHook, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

vi.mock('@/api/crms', () => ({
  default: {
    get: vi.fn(),
    list: vi.fn(),
    listObjects: vi.fn(),
    listPeople: vi.fn(),
  },
}))

const { Route } = await import('@/routes/_authenticated/$crmId/index')
const { Route: ObjectRoute } =
  await import('@/routes/_authenticated/$crmId/$objectId')
const { Route: LayoutRoute } = await import('@/routes/_authenticated/route')
const { useCrmsStore } = await import('@/stores/crms-store')
const crmsApi = (await import('@/api/crms')).default
const { createQueryClient, entityObjectsQuery, entityPeopleQuery } =
  await import('@mochi/web')
const { QueryClientProvider, useQuery } = await import('@tanstack/react-query')

const api = vi.mocked(crmsApi)

type Loader = (context: {
  params: { crmId: string; objectId?: string }
  context: { queryClient: QueryClient }
}) => Promise<{ crm: unknown; loaderError: string | null }>

describe('crm route lists', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    api.listObjects.mockResolvedValue({
      data: { objects: [], watched: [] },
    } as never)
    api.listPeople.mockResolvedValue({ data: { people: [] } } as never)
  })

  for (const [name, route, params] of [
    ['CRM page', Route, { crmId: 'c1' }],
    ['item address', ObjectRoute, { crmId: 'c1', objectId: 'o1' }],
  ] as const) {
    it(`asks for the items and people beside the details on the ${name}`, async () => {
      // The details here never answer, and both lists are still asked.
      api.get.mockReturnValue(new Promise(() => {}) as never)
      void (route.options.loader as Loader)({
        params,
        context: { queryClient: createQueryClient() },
      })
      await waitFor(() => expect(api.listObjects).toHaveBeenCalledWith('c1'))
      expect(api.listPeople).toHaveBeenCalledWith('c1')
    })
  }

  it("lets the page's own queries use what the loader started", async () => {
    api.get.mockResolvedValue({ data: { crm: { id: 'c1' } } } as never)
    const queryClient = createQueryClient()
    await (Route.options.loader as Loader)({
      params: { crmId: 'c1' },
      context: { queryClient },
    })
    const wrapper = ({ children }: { children: ReactNode }) =>
      createElement(QueryClientProvider, { client: queryClient }, children)
    const objects = renderHook(
      () => useQuery(entityObjectsQuery(crmsApi.listObjects, 'c1')),
      { wrapper }
    )
    const people = renderHook(
      () => useQuery(entityPeopleQuery(crmsApi.listPeople, 'c1')),
      { wrapper }
    )
    await waitFor(() => expect(objects.result.current.isSuccess).toBe(true))
    await waitFor(() => expect(people.result.current.isSuccess).toBe(true))
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(api.listObjects).toHaveBeenCalledTimes(1)
    expect(api.listPeople).toHaveBeenCalledTimes(1)
  })
})

describe('authenticated layout route', () => {
  it('starts the sidebar list beside the page, once', async () => {
    const list = vi.mocked(crmsApi.list)
    list.mockResolvedValue({ data: { crms: [] } } as never)
    useCrmsStore.setState({ started: false })
    const layoutLoader = LayoutRoute.options.loader as () => void
    layoutLoader()
    expect(list).toHaveBeenCalledTimes(1)
    await useCrmsStore.getState().load()
    expect(list).toHaveBeenCalledTimes(1)
    layoutLoader()
    expect(list).toHaveBeenCalledTimes(1)
  })
})
