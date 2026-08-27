import type { TokenAmount } from "../types/aura";

export function shorten(value: string, leading = 6, trailing = 4): string {
  if (value.length <= leading + trailing + 3) return value;
  return `${value.slice(0, leading)}…${value.slice(-trailing)}`;
}

export function formatAmount(amount: TokenAmount): string {
  const maximumFractionDigits =
    amount.decimals ?? (amount.value >= 100 ? 2 : 4);
  return `${new Intl.NumberFormat("en-US", {
    maximumFractionDigits,
    minimumFractionDigits: amount.value > 0 && amount.value < 1 ? 4 : 0,
  }).format(amount.value)} ${amount.symbol}`;
}

export function formatPercent(value: number): string {
  return `${new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 }).format(value)}%`;
}

export function formatCompactUsd(value: number): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  }).format(value);
}

export function orderDirectionLabel(
  direction: "token0-to-token1" | "token1-to-token0",
): string {
  return direction === "token0-to-token1" ? "USDC → WETH" : "WETH → USDC";
}
