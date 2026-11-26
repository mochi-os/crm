// Copyright © 2026 Mochisoft OÜ
// SPDX-License-Identifier: AGPL-3.0-only
// This file is part of Mochi, licensed under the GNU AGPL v3 with the
// Mochi Application Interface Exception - see license.txt and license-exception.md.
// A route file is split by TanStack: its page goes to a chunk loaded on
// demand, and the rest stays in the first load. Anything another file imports
// from a route file stays in the first load too, with everything it uses. The
// CRM page body once sat in the first load this way, more than doubling it.
// So no source file but the generated route tree may import a route file.
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const SRC = resolve(__dirname)
const ROUTES = join(SRC, 'routes')

function files(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return files(path)
    return /\.tsx?$/.test(entry.name) ? [path] : []
  })
}

// Where an import lands, for the two forms this app uses: '@/...' and relative
function target(from: string, specifier: string): string | null {
  if (specifier.startsWith('@/')) return join(SRC, specifier.slice(2))
  if (specifier.startsWith('.')) return resolve(dirname(from), specifier)
  return null
}

describe('route files', () => {
  it('are imported by nothing but the route tree', () => {
    const offenders: string[] = []
    for (const file of files(SRC)) {
      if (/\.test\.tsx?$/.test(file) || file.endsWith('routeTree.gen.ts'))
        continue
      const code = readFileSync(file, 'utf8')
      for (const match of code.matchAll(
        /^import\s+(?!type\b)[^'"]*['"]([^'"]+)['"]/gm
      )) {
        const landed = target(file, match[1])
        if (landed && landed.startsWith(ROUTES + '/'))
          offenders.push(`${relative(SRC, file)} imports ${match[1]}`)
      }
    }
    expect(offenders).toEqual([])
  })
})
