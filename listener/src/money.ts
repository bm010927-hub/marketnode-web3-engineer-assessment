/**
 * Render a base-unit amount as an exact decimal string.
 *
 * Uses only bigint and string operations: no value ever passes through a JavaScript number.
 * The fractional part is left-padded to `decimals` digits, insignificant trailing zeroes are
 * trimmed, no dangling decimal point is emitted, and zero is always "0".
 */
export function formatTokenAmount(raw: bigint, decimals: number): string {
  if (typeof raw !== "bigint") {
    throw new TypeError("raw amount must be a bigint");
  }
  if (typeof decimals !== "number" || !Number.isSafeInteger(decimals) || decimals < 0) {
    throw new RangeError("decimals must be a non-negative safe integer");
  }

  if (raw === 0n) return "0";

  const negative = raw < 0n;
  const digits = (negative ? -raw : raw).toString();

  let whole: string;
  let fraction: string;
  if (decimals === 0) {
    whole = digits;
    fraction = "";
  } else {
    const padded = digits.padStart(decimals + 1, "0");
    whole = padded.slice(0, padded.length - decimals);
    fraction = padded.slice(padded.length - decimals).replace(/0+$/, "");
  }

  const body = fraction.length > 0 ? `${whole}.${fraction}` : whole;
  return negative ? `-${body}` : body;
}

