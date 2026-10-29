// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
import {
  QueryClient,
  QueryClientProvider,
  useQuery,
} from '@tanstack/react-query'
import type { CrmDetails, CrmField } from '@/types'
import { i18n } from '@lingui/core'
import { I18nProvider } from '@lingui/react'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import crmsApi from '@/api/crms'
import { DesignEditor } from './design-editor'

const toastError = vi.hoisted(() => vi.fn())

vi.mock('@/api/crms', () => ({
  default: {
    listObjects: vi.fn(),
    reorderFields: vi.fn(),
    reorderViews: vi.fn(),
  },
}))
vi.mock('@mochi/web', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@mochi/web')>()),
  toast: { error: toastError },
}))
vi.mock('./design-preview', () => ({ DesignPreview: () => null }))
// The class sheet owns the field drag; here it lists the fields in the order
// it is given and offers one button that reverses them.
vi.mock('./edit-dialogs', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./edit-dialogs')>()),
  ClassSheet: ({
    mode,
    fields,
    onReorderFields,
  }: {
    mode?: string
    fields?: CrmField[]
    onReorderFields?: (order: string[]) => void
  }) =>
    mode === 'create' ? null : (
      <>
        <p>fields {fields?.map((field) => field.name).join(', ')}</p>
        <button
          onClick={() =>
            onReorderFields?.((fields ?? []).map((field) => field.id).reverse())
          }
        >
          Reverse fields
        </button>
      </>
    ),
}))

const details = {
  crm: { id: 'c1', name: 'Sales', populated: 1, access: 'owner' },
  classes: [{ id: 'task', name: 'Task' }],
  fields: {
    task: [
      { id: 'title', name: 'Title' },
      { id: 'owner', name: 'Owner' },
    ],
  },
  options: {},
  views: [
    { id: 'board', name: 'Board' },
    { id: 'list', name: 'List' },
  ],
  hierarchy: {},
} as unknown as CrmDetails

// The design page reads the details from this query and hands them down, as
// EntityDesignPage does.
function Page() {
  const { data } = useQuery({
    queryKey: ['crm', 'c1'],
    queryFn: () => details,
  })
  return data ? <DesignEditor crmId='c1' crm={data} /> : null
}

function show() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity } },
  })
  return render(
    <I18nProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <Page />
      </QueryClientProvider>
    </I18nProvider>
  )
}

const views = () =>
  screen.getAllByText(/^(Board|List)$/).map((element) => element.textContent)

function dragView(from: string, to: string) {
  const dataTransfer = { setData: () => {}, effectAllowed: '' }
  const row = (name: string) => screen.getByText(name).closest('[draggable]')!
  fireEvent.dragStart(row(from), { dataTransfer })
  fireEvent.dragOver(row(to), { dataTransfer })
  fireEvent.drop(row(to), { dataTransfer })
}

function waiting() {
  let reject!: (error: unknown) => void
  const promise = new Promise((_resolve, rej) => {
    reject = rej
  })
  return { promise, reject }
}

// A dragged field or view takes its place on the drop, and goes back with a
// toast if the server refuses the order.
describe('DesignEditor reorder', () => {
  beforeEach(() => {
    toastError.mockReset()
    vi.mocked(crmsApi.listObjects).mockResolvedValue({
      data: { objects: [] },
    } as never)
  })

  it('moves a view at once and back when refused', async () => {
    const request = waiting()
    vi.mocked(crmsApi.reorderViews).mockReturnValue(request.promise as never)
    show()
    await waitFor(() => expect(views()).toEqual(['Board', 'List']))

    dragView('Board', 'List')
    await waitFor(() => expect(views()).toEqual(['List', 'Board']))
    expect(crmsApi.reorderViews).toHaveBeenCalledWith('c1', ['list', 'board'])

    request.reject({ response: { status: 500 } })
    await waitFor(() => expect(views()).toEqual(['Board', 'List']))
    expect(toastError).toHaveBeenCalledWith('Failed to reorder views')
  })

  it('moves a field at once and back when refused', async () => {
    const request = waiting()
    vi.mocked(crmsApi.reorderFields).mockReturnValue(request.promise as never)
    show()
    expect(await screen.findByText('fields Title, Owner')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Reverse fields' }))
    expect(await screen.findByText('fields Owner, Title')).toBeInTheDocument()
    expect(crmsApi.reorderFields).toHaveBeenCalledWith('c1', 'task', [
      'owner',
      'title',
    ])

    request.reject({ response: { status: 500 } })
    expect(await screen.findByText('fields Title, Owner')).toBeInTheDocument()
    expect(toastError).toHaveBeenCalledWith('Failed to reorder fields')
  })
})
