import { expect, test } from "vitest";
import { formatTokenAmount } from "../src/money.js";

test("REG-06 formats the specified examples exactly", () => {
  expect(formatTokenAmount(0n, 18)).toBe("0");
  expect(formatTokenAmount(1n, 18)).toBe("0.000000000000000001");
  expect(formatTokenAmount(1_500_000n, 6)).toBe("1.5");
  expect(formatTokenAmount(5_000n * 10n ** 18n, 18)).toBe("5000");
});

test("REG-06 formats amounts above Number.MAX_SAFE_INTEGER without precision loss", () => {
  const unsafe = BigInt(Number.MAX_SAFE_INTEGER) + 2n; // 9007199254740993
  expect(formatTokenAmount(unsafe, 0)).toBe("9007199254740993");
  expect(formatTokenAmount(unsafe, 18)).toBe("0.009007199254740993");
  expect(formatTokenAmount(123_456_789_012_345_678_901_234_567n, 18)).toBe("123456789.012345678901234567");
  expect(formatTokenAmount(10n ** 30n + 1n, 18)).toBe("1000000000000.000000000000000001");
});

test("REG-06 pads leading fractional zeroes and trims only trailing ones", () => {
  expect(formatTokenAmount(5n, 3)).toBe("0.005");
  expect(formatTokenAmount(1_050n, 3)).toBe("1.05");
  expect(formatTokenAmount(100_000_000_000_000_000n, 18)).toBe("0.1");
  expect(formatTokenAmount(1_000_000_000_000_000_010n, 18)).toBe("1.00000000000000001");
});

test("REG-06 never emits an unnecessary decimal point", () => {
  expect(formatTokenAmount(2_000_000n, 6)).toBe("2");
  expect(formatTokenAmount(1_000n * 10n ** 18n, 18)).toBe("1000");
  expect(formatTokenAmount(42n, 0)).toBe("42");
  expect(formatTokenAmount(-3_000n, 3)).toBe("-3");
});

test("REG-06 keeps exactly one leading minus sign for negative input", () => {
  expect(formatTokenAmount(-1n, 18)).toBe("-0.000000000000000001");
  expect(formatTokenAmount(-1_500_000n, 6)).toBe("-1.5");
  expect(formatTokenAmount(-(10n ** 30n), 18)).toBe("-1000000000000");
});

test("REG-06 renders zero as 0 for every valid decimals value", () => {
  for (const decimals of [0, 1, 6, 18, 36]) {
    expect(formatTokenAmount(0n, decimals)).toBe("0");
  }
  expect(Object.is(formatTokenAmount(-0n, 6), "0")).toBe(true);
  expect(formatTokenAmount(-0n, 18)).toBe("0");
});

test("REG-06 honours the decimals argument instead of assuming 18", () => {
  expect(formatTokenAmount(1_234_567n, 2)).toBe("12345.67");
  expect(formatTokenAmount(7n, 1)).toBe("0.7");
  expect(formatTokenAmount(123n, 0)).toBe("123");
  expect(formatTokenAmount(1n, 36)).toBe("0.000000000000000000000000000000000001");
});

test("REG-06 rejects decimals that are not non-negative safe integers", () => {
  for (const bad of [-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, 2 ** 53]) {
    expect(() => formatTokenAmount(1n, bad)).toThrow();
  }
});