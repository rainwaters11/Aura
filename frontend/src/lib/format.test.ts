import { describe, expect, it } from "vitest";

import {
  formatAmount,
  formatCompactUsd,
  formatPercent,
  orderDirectionLabel,
  shorten,
} from "./format";

describe("display formatting", () => {
  it("shortens long identifiers without changing short labels", () => {
    expect(shorten("0x1234567890abcdef")).toBe("0x1234…cdef");
    expect(shorten("Alice")).toBe("Alice");
  });

  it("formats token amounts, percentages, and notional values consistently", () => {
    expect(formatAmount({ symbol: "WETH", value: 0.8032 })).toBe("0.8032 WETH");
    expect(formatAmount({ symbol: "USDC", value: 8_000, decimals: 0 })).toBe(
      "8,000 USDC",
    );
    expect(formatPercent(88.88)).toBe("88.9%");
    expect(formatCompactUsd(18_000)).toBe("$18,000");
  });

  it("uses familiar directional labels", () => {
    expect(orderDirectionLabel("token0-to-token1")).toBe("USDC → WETH");
    expect(orderDirectionLabel("token1-to-token0")).toBe("WETH → USDC");
  });
});
