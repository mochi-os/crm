// Fractional-index rank keys (#53) — client mirror of the canonical
// fractional-indexing in apps/projects/projects.star (Evan Wallace's algorithm:
// integer header + fractional part; append/prepend increment/decrement the
// header, only between bisects). Floor midpoint (`>> 1`) matches the Starlark
// `// 2` so the optimistic drag preview lands where the server will. Used only
// for the optimistic preview; the server computes the authoritative key.
const D = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const HEADERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const SMALLEST = "A" + "0".repeat(26);

function intLength(head: string): number {
  const i = HEADERS.indexOf(head);
  return i >= 26 ? i - 26 + 2 : 25 - i + 2;
}

function intPart(key: string): string {
  return key.slice(0, intLength(key[0]));
}

function increment(x: string): string | null {
  const head = x[0];
  const digits = x.slice(1).split("");
  let carry = true;
  for (let i = digits.length - 1; carry && i >= 0; i--) {
    const d = D.indexOf(digits[i]) + 1;
    if (d === 62) digits[i] = D[0];
    else {
      digits[i] = D[d];
      carry = false;
    }
  }
  if (!carry) return head + digits.join("");
  if (head === "Z") return "a" + D[0];
  if (head === "z") return null;
  const h = HEADERS[HEADERS.indexOf(head) + 1];
  if (HEADERS.indexOf(h) >= 26) digits.push(D[0]);
  else digits.pop();
  return h + digits.join("");
}

function decrement(x: string): string | null {
  const head = x[0];
  const digits = x.slice(1).split("");
  let borrow = true;
  for (let i = digits.length - 1; borrow && i >= 0; i--) {
    const d = D.indexOf(digits[i]) - 1;
    if (d === -1) digits[i] = D[61];
    else {
      digits[i] = D[d];
      borrow = false;
    }
  }
  if (!borrow) return head + digits.join("");
  if (head === "a") return "Z" + D[61];
  if (head === "A") return null;
  const h = HEADERS[HEADERS.indexOf(head) - 1];
  if (HEADERS.indexOf(h) < 26) digits.push(D[61]);
  else digits.pop();
  return h + digits.join("");
}

function midpoint(a: string, b: string | null): string {
  const zero = D[0];
  if (b !== null && b.length > 0) {
    let n = 0;
    for (;;) {
      const ca = n < a.length ? a[n] : zero;
      if (ca !== b[n]) break;
      n++;
      if (n >= b.length) break;
    }
    if (n > 0) return b.slice(0, n) + midpoint(a.slice(n), b.slice(n));
  }
  const da = a.length > 0 ? D.indexOf(a[0]) : 0;
  const db = b !== null && b.length > 0 ? D.indexOf(b[0]) : 62;
  if (db - da > 1) return D[(da + db) >> 1];
  if (b !== null && b.length > 1) return b.slice(0, 1);
  return D[da] + midpoint(a.length > 0 ? a.slice(1) : "", null);
}

// A key strictly between a and b (either null = before-all / after-all).
export function rankBetween(a: string | null, b: string | null): string {
  if (a === null && b === null) return "a" + D[0];
  if (a === null) {
    const ib = intPart(b!);
    const fb = b!.slice(ib.length);
    if (ib === SMALLEST) return ib + midpoint("", fb);
    if (ib < b!) return ib;
    return decrement(ib)!;
  }
  if (b === null) {
    const ia = intPart(a);
    const fa = a.slice(ia.length);
    const i = increment(ia);
    return i === null ? ia + midpoint(fa, null) : i;
  }
  const ia = intPart(a);
  const fa = a.slice(ia.length);
  const ib = intPart(b);
  const fb = b.slice(ib.length);
  if (ia === ib) return ia + midpoint(fa, fb);
  const i = increment(ia);
  if (i !== null && i < b) return i;
  return ia + midpoint(fa, null);
}

// Lexicographic compare for opaque rank keys (BINARY order). Deliberately NOT
// naturalCompare — these are opaque ordering keys, not user-facing strings.
export function rankCompare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
