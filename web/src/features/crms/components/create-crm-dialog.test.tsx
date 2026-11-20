// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
// Tests for CreateCrmDialog component
import { render, screen, fireEvent, waitFor } from '@/test/test-utils'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { CreateCrmDialog } from './create-crm-dialog'

// Mock navigation
const mockNavigate = vi.fn()
vi.mock('@tanstack/react-router', () => ({
  useNavigate: () => mockNavigate,
}))

// Mock crmsApi
const mockCreate = vi.fn()
vi.mock('@/api/crms', () => ({
  default: {
    create: (...args: unknown[]) => mockCreate(...args),
  },
}))

// Mock store
vi.mock('@/stores/crms-store', () => ({
  useCrmsStore: (selector: (s: { refresh: () => Promise<void> }) => unknown) =>
    selector({ refresh: vi.fn() }),
}))

describe('CreateCrmDialog', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('should render dialog when open', () => {
    render(<CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />)

    expect(screen.getByLabelText('Name')).toBeInTheDocument()
    // "Create CRM" appears in both title and button
    expect(screen.getAllByText('Create CRM').length).toBeGreaterThanOrEqual(1)
  })

  it('should call create API on submit', async () => {
    mockCreate.mockResolvedValue({ data: { id: '123', fingerprint: 'abc' } })

    render(<CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />)

    fireEvent.change(screen.getByLabelText('Name'), {
      target: { value: 'Test CRM' },
    })

    fireEvent.click(screen.getByRole('button', { name: /Create CRM/i }))

    await waitFor(() => {
      expect(mockCreate).toHaveBeenCalledWith({
        name: 'Test CRM',
        privacy: 'private',
      })
    })
  })

  it('should show trigger button when hideTrigger is false', () => {
    render(<CreateCrmDialog open={false} onOpenChange={vi.fn()} />)

    expect(
      screen.getByRole('button', { name: /Create CRM/i })
    ).toBeInTheDocument()
  })

  it('should have privacy toggle defaulting to private', () => {
    render(<CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />)

    expect(
      screen.getByRole('switch', {
        name: 'Allow anyone to view and comment on CRM',
      })
    ).not.toBeChecked()
  })

  it('creates a public CRM with the switch on', async () => {
    mockCreate.mockResolvedValue({ data: { id: '123', fingerprint: 'abc' } })

    render(<CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />)

    fireEvent.change(screen.getByLabelText('Name'), {
      target: { value: 'Open CRM' },
    })
    fireEvent.click(
      screen.getByRole('switch', {
        name: 'Allow anyone to view and comment on CRM',
      })
    )
    fireEvent.click(screen.getByRole('button', { name: /Create CRM/i }))

    await waitFor(() => {
      expect(mockCreate).toHaveBeenCalledWith({
        name: 'Open CRM',
        privacy: 'public',
      })
    })
  })

  it('turns the switch off again when the dialog closes', () => {
    const name = 'Allow anyone to view and comment on CRM'
    const { rerender } = render(
      <CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />
    )
    fireEvent.click(screen.getByRole('switch', { name }))
    expect(screen.getByRole('switch', { name })).toBeChecked()

    rerender(
      <CreateCrmDialog open={false} onOpenChange={vi.fn()} hideTrigger />
    )
    rerender(<CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />)

    expect(screen.getByRole('switch', { name })).not.toBeChecked()
  })

  it('should include descriptive dialog text for assistive tech', () => {
    render(<CreateCrmDialog open={true} onOpenChange={vi.fn()} hideTrigger />)

    expect(screen.getByText('Create a new CRM')).toBeInTheDocument()
  })
})
