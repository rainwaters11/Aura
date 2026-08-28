import type {
  AuraDataSource,
  AuraSnapshot,
  ClaimRecord,
  ParkedOrder,
  ScenarioKind,
  SettlementResult,
} from "../types/aura";

const COMMIT_SHA = "4198d1ed5dcd44fc42b7384e31dabaa399d79722";
const localHash = (prefix: string) => `0x${prefix.padEnd(64, "0")}`;
const POOL_ID = localHash("a013c0a5");
const HOOK_ADDRESS = "0x00000000000000000000000000000000000a0088";
const ALICE = "0x00000000000000000000000000000000000a11ce";
const BOB = "0x0000000000000000000000000000000000000b0b";
const ALICE_RECIPIENT = "0x0000000000000000000000000000000000a11ce1";
const BOB_RECIPIENT = "0x00000000000000000000000000000000000b0b02";
const MAX_BATCH_WINDOW = 20;
const DEMO_OPENED_AT_BLOCK = 1_000_000;
const DEMO_CURRENT_BLOCK = DEMO_OPENED_AT_BLOCK + MAX_BATCH_WINDOW + 1;

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

function ordersFor(scenario: ScenarioKind): ParkedOrder[] {
  const usdcAmount = scenario === "perfect-cow" ? 8_000 : 10_000;
  return [
    {
      id: localHash("01a11ce"),
      ownerLabel: "Alice",
      owner: ALICE,
      recipient: ALICE_RECIPIENT,
      direction: "token0-to-token1",
      amountIn: { symbol: "USDC", value: usdcAmount, decimals: 0 },
      minAmountOut: {
        symbol: "WETH",
        value: scenario === "perfect-cow" ? 3.18 : 3.98,
      },
      deadline: "13h 00m remaining",
      status: "PARKED",
    },
    {
      id: localHash("02b0b"),
      ownerLabel: "Bob",
      owner: BOB,
      recipient: BOB_RECIPIENT,
      direction: "token1-to-token0",
      amountIn: { symbol: "WETH", value: 3.2 },
      minAmountOut: { symbol: "USDC", value: 7_960, decimals: 0 },
      deadline: "13h 00m remaining",
      status: "PARKED",
    },
  ];
}

function settlementFor(scenario: ScenarioKind): SettlementResult {
  const perfectCow = scenario === "perfect-cow";
  return {
    batchId: 1,
    solutionHash: perfectCow ? localHash("c0a00001") : localHash("5e771e01"),
    totalNotional: perfectCow ? 16_000 : 18_000,
    directMatchNotional: 16_000,
    residualNotional: perfectCow ? 0 : 2_000,
    directMatchPercent: perfectCow ? 100 : 88.9,
    residualPercent: perfectCow ? 0 : 11.1,
    uniformPrice: "2,500 USDC / WETH",
    residualInput: {
      symbol: "USDC",
      value: perfectCow ? 0 : 2_000,
      decimals: 0,
    },
    realizedOutput: { symbol: "WETH", value: perfectCow ? 0 : 0.8032 },
    protocolDust: { symbol: "WETH", value: perfectCow ? 0 : 0.0032 },
    zeroUnresolvedDeltas: true,
    poolMoved: !perfectCow,
  };
}

function claimsFor(scenario: ScenarioKind): ClaimRecord[] {
  return [
    {
      accountLabel: "Alice",
      account: ALICE_RECIPIENT,
      recipient: ALICE_RECIPIENT,
      amount: { symbol: "WETH", value: scenario === "perfect-cow" ? 3.2 : 4 },
      status: "available",
    },
    {
      accountLabel: "Bob",
      account: BOB_RECIPIENT,
      recipient: BOB_RECIPIENT,
      amount: { symbol: "USDC", value: 8_000, decimals: 0 },
      status: "available",
    },
  ];
}

function initialSnapshot(scenario: ScenarioKind): AuraSnapshot {
  return {
    scenario,
    phase: "empty",
    pool: {
      pair: "Mock USDC / Mock WETH",
      poolId: POOL_ID,
      hookAddress: HOOK_ADDRESS,
      feeTier: "0.30%",
      network: "Local deterministic fixture",
      chainId: 31_337,
      connection: "ready",
      before: { price: 2_500, tick: 78_244, liquidity: "1.20M" },
      after: { price: 2_500, tick: 78_244, liquidity: "1.20M" },
    },
    batchWindow: null,
    orders: [],
    settlement: null,
    claims: [],
    evidence: [
      { label: "Source commit", value: COMMIT_SHA, kind: "Local simulation" },
      { label: "Pool ID", value: POOL_ID, kind: "Local simulation" },
      { label: "Hook fixture", value: HOOK_ADDRESS, kind: "Local simulation" },
    ],
  };
}

export function createLocalAuraDataSource(latencyMs = 420): AuraDataSource {
  async function pause() {
    await delay(latencyMs);
  }

  return {
    mode: "Local simulation",
    async getInitialSnapshot(scenario) {
      await pause();
      return initialSnapshot(scenario);
    },
    async parkDemoOrders(snapshot) {
      await pause();
      const next = clone(snapshot);
      next.phase = "parked";
      next.orders = ordersFor(snapshot.scenario);
      next.batchWindow = {
        openedAtBlock: DEMO_OPENED_AT_BLOCK,
        currentBlock: DEMO_CURRENT_BLOCK,
        maxWindowBlocks: MAX_BATCH_WINDOW,
      };
      next.evidence.push(
        {
          label: "Order trace · Alice",
          value: "local-order-a11ce-0001",
          kind: "Local simulation",
        },
        {
          label: "Order trace · Bob",
          value: "local-order-b0b-0002",
          kind: "Local simulation",
        },
        {
          label: "Batch intake window",
          value: `opened ${DEMO_OPENED_AT_BLOCK} · current ${DEMO_CURRENT_BLOCK} · ${MAX_BATCH_WINDOW + 1} blocks elapsed`,
          kind: "Local simulation",
        },
      );
      return next;
    },
    async closeBatch(snapshot) {
      await pause();
      if (snapshot.phase !== "parked" || !snapshot.batchWindow) {
        throw new Error(
          "Park the deterministic orders before closing the batch.",
        );
      }
      const { openedAtBlock, currentBlock, maxWindowBlocks } =
        snapshot.batchWindow;
      if (currentBlock <= openedAtBlock + maxWindowBlocks) {
        throw new Error(
          `The ${maxWindowBlocks}-block intake window is still active. Advance beyond block ${openedAtBlock + maxWindowBlocks} before closing.`,
        );
      }
      const next = clone(snapshot);
      next.phase = "closed";
      next.evidence.push({
        label: "Batch closure",
        value: `local-batch-0001-closed-at-${currentBlock}`,
        kind: "Local simulation",
      });
      return next;
    },
    async settleBatch(snapshot) {
      await pause();
      const next = clone(snapshot);
      next.phase = "settled";
      next.orders = next.orders.map((order) => ({
        ...order,
        status: "SETTLED",
      }));
      next.settlement = settlementFor(snapshot.scenario);
      next.pool.after =
        snapshot.scenario === "perfect-cow"
          ? clone(next.pool.before)
          : { price: 2_504.2, tick: 78_261, liquidity: "1.20M" };
      next.claims = claimsFor(snapshot.scenario);
      next.evidence.push(
        {
          label: "Solution hash",
          value: next.settlement.solutionHash,
          kind: "Local simulation",
        },
        {
          label: "Settlement trace",
          value: "local-settlement-0001",
          kind: "Local simulation",
        },
        {
          label: "PoolManager deltas",
          value: "token0: 0 · token1: 0",
          kind: "Local simulation",
        },
      );
      return next;
    },
    async claimOutput(snapshot, account, recipient) {
      await pause();
      const next = clone(snapshot);
      const claim = next.claims.find((entry) => entry.account === account);
      if (!claim || claim.status !== "available")
        throw new Error("This account has no available output to claim.");
      if (
        !/^0x[0-9a-fA-F]{40}$/.test(recipient) ||
        /^0x0{40}$/i.test(recipient)
      )
        throw new Error("Enter a valid nonzero recipient address.");
      if (recipient.toLowerCase().endsWith("dead")) {
        throw new Error(
          "Recipient rejected the token transfer. Alice’s claim remains fully available and Bob is unaffected.",
        );
      }
      claim.status = "claimed";
      claim.recipient = recipient;
      claim.traceId = "local-claim-a11ce-0001";
      next.phase = "claimed";
      next.evidence.push({
        label: "Claim trace · Alice",
        value: claim.traceId,
        kind: "Local simulation",
      });
      return next;
    },
    async reset(scenario) {
      await pause();
      return initialSnapshot(scenario);
    },
  };
}

export const localAuraDataSource = createLocalAuraDataSource();
