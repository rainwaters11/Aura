export type ScenarioKind = "residual" | "perfect-cow";

export type DemoPhase = "empty" | "parked" | "closed" | "settled" | "claimed";

export type ActionName = "load" | "close" | "settle" | "claim" | "reset";

export type ActionState = "idle" | "pending" | "success" | "error";

export type OrderStatus = "PARKED" | "SETTLED" | "REFUNDABLE";

export type EvidenceKind =
  "Local simulation" | "Anvil evidence" | "Unichain Sepolia evidence";

export interface TokenAmount {
  symbol: string;
  value: number;
  decimals?: number;
}

export interface PoolState {
  price: number;
  tick: number;
  liquidity: string;
}

export interface PoolProof {
  pair: string;
  poolId: string;
  hookAddress: string;
  feeTier: string;
  network: string;
  chainId: number;
  connection: "ready" | "disconnected" | "wrong-network" | "unavailable";
  before: PoolState;
  after: PoolState;
}

export interface ParkedOrder {
  id: string;
  ownerLabel: string;
  owner: string;
  recipient: string;
  direction: "token0-to-token1" | "token1-to-token0";
  amountIn: TokenAmount;
  minAmountOut: TokenAmount;
  deadline: string;
  status: OrderStatus;
}

export interface SettlementResult {
  batchId: number;
  solutionHash: string;
  totalNotional: number;
  directMatchNotional: number;
  residualNotional: number;
  directMatchPercent: number;
  residualPercent: number;
  uniformPrice: string;
  residualInput: TokenAmount;
  realizedOutput: TokenAmount;
  protocolDust: TokenAmount;
  zeroUnresolvedDeltas: boolean;
  poolMoved: boolean;
}

export interface ClaimRecord {
  accountLabel: string;
  account: string;
  recipient: string;
  amount: TokenAmount;
  status: "empty" | "available" | "pending" | "claimed" | "failed";
  traceId?: string;
}

export interface EvidenceRecord {
  label: string;
  value: string;
  kind: EvidenceKind;
}

export interface AuraSnapshot {
  scenario: ScenarioKind;
  phase: DemoPhase;
  pool: PoolProof;
  orders: ParkedOrder[];
  settlement: SettlementResult | null;
  claims: ClaimRecord[];
  evidence: EvidenceRecord[];
}

export interface AuraDataSource {
  readonly mode: EvidenceKind;
  getInitialSnapshot(scenario: ScenarioKind): Promise<AuraSnapshot>;
  parkDemoOrders(snapshot: AuraSnapshot): Promise<AuraSnapshot>;
  closeBatch(snapshot: AuraSnapshot): Promise<AuraSnapshot>;
  settleBatch(snapshot: AuraSnapshot): Promise<AuraSnapshot>;
  claimOutput(
    snapshot: AuraSnapshot,
    account: string,
    recipient: string,
  ): Promise<AuraSnapshot>;
  reset(scenario: ScenarioKind): Promise<AuraSnapshot>;
}
