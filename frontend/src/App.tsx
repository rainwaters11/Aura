import { useEffect, useMemo, useState, type ReactNode } from "react";
import {
  Activity,
  AlertCircle,
  ArrowDownRight,
  ArrowRight,
  ArrowUpRight,
  BadgeCheck,
  Check,
  CheckCircle2,
  ChevronDown,
  CircleDollarSign,
  Clock3,
  Coins,
  Copy,
  Database,
  ExternalLink,
  Gauge,
  GitBranch,
  Layers3,
  LockKeyhole,
  Network,
  Orbit,
  Play,
  RefreshCw,
  Route,
  ShieldCheck,
  Sparkles,
  Unplug,
  WalletCards,
  XCircle,
  type LucideIcon,
} from "lucide-react";

import { localAuraDataSource } from "./data/localAuraDataSource";
import {
  formatAmount,
  formatCompactUsd,
  formatPercent,
  orderDirectionLabel,
  shorten,
} from "./lib/format";
import type {
  ActionName,
  AuraDataSource,
  AuraSnapshot,
  DemoPhase,
  EvidenceKind,
  ParkedOrder,
  ScenarioKind,
} from "./types/aura";

type PreviewMode =
  "normal" | "disconnected" | "wrong-network" | "unavailable" | "claim-error";

interface AppProps {
  dataSource?: AuraDataSource;
  previewMode?: PreviewMode;
}

const STAGES: Array<{
  phase: DemoPhase;
  label: string;
  helper: string;
  icon: LucideIcon;
}> = [
  {
    phase: "parked",
    label: "Park",
    helper: "Inputs leave the curve untouched",
    icon: LockKeyhole,
  },
  {
    phase: "closed",
    label: "Match",
    helper: "One price across both directions",
    icon: GitBranch,
  },
  {
    phase: "settled",
    label: "Settle residual",
    helper: "Only the difference reaches v4",
    icon: Route,
  },
  {
    phase: "claimed",
    label: "Claim",
    helper: "Owners pull to their recipient",
    icon: WalletCards,
  },
];

const PHASE_RANK: Record<DemoPhase, number> = {
  empty: 0,
  parked: 1,
  closed: 2,
  settled: 3,
  claimed: 4,
};

function getPreviewMode(): PreviewMode {
  if (typeof window === "undefined") return "normal";
  const value = new URLSearchParams(window.location.search).get("preview");
  if (
    value === "disconnected" ||
    value === "wrong-network" ||
    value === "unavailable" ||
    value === "claim-error"
  ) {
    return value;
  }
  return "normal";
}

function AuraMark() {
  return (
    <div className="aura-mark" aria-hidden="true">
      <span className="aura-mark__orbit" />
      <span className="aura-mark__core">A</span>
    </div>
  );
}

function StatusPill({
  tone = "neutral",
  children,
}: {
  tone?: "neutral" | "success" | "gold" | "danger";
  children: ReactNode;
}) {
  return <span className={`status-pill status-pill--${tone}`}>{children}</span>;
}

function Metric({
  label,
  value,
  helper,
  icon: Icon,
}: {
  label: string;
  value: string;
  helper: string;
  icon: LucideIcon;
}) {
  return (
    <div className="metric-card">
      <span className="metric-card__icon">
        <Icon size={18} aria-hidden="true" />
      </span>
      <div>
        <p>{label}</p>
        <strong>{value}</strong>
        <small>{helper}</small>
      </div>
    </div>
  );
}

function CopyValue({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    await navigator.clipboard?.writeText(value);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1_200);
  }
  return (
    <button
      className="copy-value"
      type="button"
      onClick={copy}
      aria-label={`Copy ${label}`}
    >
      <span>{shorten(value, 10, 6)}</span>
      {copied ? (
        <Check size={14} aria-hidden="true" />
      ) : (
        <Copy size={14} aria-hidden="true" />
      )}
    </button>
  );
}

function StageRail({ phase }: { phase: DemoPhase }) {
  const currentRank = PHASE_RANK[phase];
  return (
    <section className="stage-rail" aria-labelledby="journey-title">
      <div className="section-kicker">
        <Orbit size={14} aria-hidden="true" /> Live batch journey
      </div>
      <h2 id="journey-title" className="sr-only">
        Aura settlement journey
      </h2>
      <ol>
        {STAGES.map((stage, index) => {
          const rank = index + 1;
          const complete =
            currentRank > rank || (currentRank === 4 && rank === 4);
          const active = currentRank === rank;
          const Icon = stage.icon;
          return (
            <li
              key={stage.phase}
              className={`${complete ? "is-complete" : ""} ${active ? "is-active" : ""}`}
            >
              <div className="stage-rail__node">
                {complete ? (
                  <Check size={17} aria-hidden="true" />
                ) : (
                  <Icon size={17} aria-hidden="true" />
                )}
              </div>
              <div>
                <span>0{index + 1}</span>
                <strong>{stage.label}</strong>
                <small>{stage.helper}</small>
              </div>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

function PoolProofCard({
  snapshot,
  mode,
}: {
  snapshot: AuraSnapshot;
  mode: EvidenceKind;
}) {
  const { pool, phase, settlement } = snapshot;
  const settled = PHASE_RANK[phase] >= PHASE_RANK.settled;
  const neutral = settled && !settlement?.poolMoved;
  const sourceCopy =
    mode === "Local simulation"
      ? {
          ready: "Local source ready",
          proof: "Verified by deterministic local accounting evidence.",
        }
      : mode === "Anvil evidence"
        ? {
            ready: "Anvil source ready",
            proof: "Verified by local Anvil execution evidence.",
          }
        : {
            ready: "Sepolia source ready",
            proof: "Verified by Unichain Sepolia execution evidence.",
          };
  return (
    <section className="panel pool-proof" aria-labelledby="pool-proof-title">
      <div className="panel__header">
        <div>
          <div className="section-kicker">
            <Layers3 size={14} aria-hidden="true" /> Bound pool
          </div>
          <h2 id="pool-proof-title">Curve proof</h2>
        </div>
        <StatusPill tone={pool.connection === "ready" ? "success" : "danger"}>
          {pool.connection === "ready"
            ? sourceCopy.ready
            : pool.connection.replace("-", " ")}
        </StatusPill>
      </div>

      <div className="token-pair">
        <div className="token-stack" aria-hidden="true">
          <span>$</span>
          <span>Ξ</span>
        </div>
        <div>
          <strong>{pool.pair}</strong>
          <small>
            {pool.network} · Chain {pool.chainId}
          </small>
        </div>
        <span className="fee-chip">{pool.feeTier} fee</span>
      </div>

      <dl className="proof-grid">
        <div>
          <dt>Pool ID</dt>
          <dd>
            <CopyValue value={pool.poolId} label="pool ID" />
          </dd>
        </div>
        <div>
          <dt>Hook fixture</dt>
          <dd>
            <CopyValue value={pool.hookAddress} label="hook fixture" />
          </dd>
        </div>
      </dl>

      <div className="state-comparison">
        <div className="state-comparison__label">
          <span>Pool state</span>
          <span>Before</span>
          <span>After</span>
        </div>
        <div>
          <span>Price</span>
          <strong>${pool.before.price.toLocaleString()}</strong>
          <strong className={neutral ? "proof-neutral" : ""}>
            ${pool.after.price.toLocaleString()}
          </strong>
        </div>
        <div>
          <span>Tick</span>
          <strong>{pool.before.tick.toLocaleString()}</strong>
          <strong className={neutral ? "proof-neutral" : ""}>
            {pool.after.tick.toLocaleString()}
          </strong>
        </div>
        <div>
          <span>Liquidity</span>
          <strong>{pool.before.liquidity}</strong>
          <strong className="proof-neutral">{pool.after.liquidity}</strong>
        </div>
      </div>

      <div
        className={`proof-callout ${settled ? "is-visible" : ""}`}
        aria-live="polite"
      >
        <ShieldCheck size={19} aria-hidden="true" />
        <div>
          <strong>
            {settled
              ? neutral
                ? "Perfect CoW: curve untouched"
                : "Only the residual moved the curve"
              : "Waiting for settlement proof"}
          </strong>
          <span>
            {settled
              ? sourceCopy.proof
              : "Complete the batch journey to compare pool state."}
          </span>
        </div>
      </div>
    </section>
  );
}

function OrderCard({ order }: { order: ParkedOrder }) {
  const token0 = order.direction === "token0-to-token1";
  const statusTone =
    order.status === "SETTLED"
      ? "success"
      : order.status === "REFUNDABLE"
        ? "danger"
        : "gold";
  return (
    <article className="order-card">
      <div className="order-card__top">
        <div
          className={`direction-mark ${token0 ? "" : "direction-mark--reverse"}`}
        >
          {token0 ? (
            <ArrowUpRight size={18} aria-hidden="true" />
          ) : (
            <ArrowDownRight size={18} aria-hidden="true" />
          )}
        </div>
        <div>
          <strong>{order.ownerLabel}</strong>
          <span>{orderDirectionLabel(order.direction)}</span>
        </div>
        <StatusPill tone={statusTone}>{order.status}</StatusPill>
      </div>
      <div className="order-card__amount">
        <span>Parked input</span>
        <strong>{formatAmount(order.amountIn)}</strong>
      </div>
      <dl>
        <div>
          <dt>Minimum output</dt>
          <dd>{formatAmount(order.minAmountOut)}</dd>
        </div>
        <div>
          <dt>Recipient</dt>
          <dd>{shorten(order.recipient)}</dd>
        </div>
        <div>
          <dt>Deadline</dt>
          <dd>
            <Clock3 size={13} aria-hidden="true" />
            {order.deadline}
          </dd>
        </div>
        <div>
          <dt>Order ID</dt>
          <dd>{shorten(order.id)}</dd>
        </div>
      </dl>
    </article>
  );
}

function OrderBoard({
  orders,
  phase,
}: {
  orders: ParkedOrder[];
  phase: DemoPhase;
}) {
  const membershipLabel =
    PHASE_RANK[phase] >= PHASE_RANK.closed
      ? "Frozen membership"
      : phase === "parked"
        ? "Intake open"
        : "Awaiting orders";
  return (
    <section className="panel order-board" aria-labelledby="orders-title">
      <div className="panel__header">
        <div>
          <div className="section-kicker">
            <Database size={14} aria-hidden="true" /> {membershipLabel}
          </div>
          <h2 id="orders-title">Parked orders</h2>
        </div>
        <StatusPill tone={orders.length ? "success" : "neutral"}>
          {orders.length}/4 demo slots
        </StatusPill>
      </div>
      {orders.length === 0 ? (
        <div className="empty-state">
          <div className="empty-state__art">
            <ArrowUpRight size={24} />
            <ArrowDownRight size={24} />
          </div>
          <strong>No orders parked yet</strong>
          <p>Load the deterministic two-sided batch to begin the judge flow.</p>
        </div>
      ) : (
        <div className="order-grid">
          {orders.map((order) => (
            <OrderCard key={order.id} order={order} />
          ))}
        </div>
      )}
    </section>
  );
}

function SettlementVisual({ snapshot }: { snapshot: AuraSnapshot }) {
  const result = snapshot.settlement;
  return (
    <section
      className={`panel settlement-visual ${result ? "has-result" : ""}`}
      aria-labelledby="settlement-title"
    >
      <div className="panel__header">
        <div>
          <div className="section-kicker">
            <Sparkles size={14} aria-hidden="true" /> Settlement intelligence
          </div>
          <h2 id="settlement-title">Move only the difference</h2>
        </div>
        {result && (
          <StatusPill tone="success">
            <CheckCircle2 size={13} /> Fully backed
          </StatusPill>
        )}
      </div>

      {!result ? (
        <div className="settlement-placeholder">
          <div className="settlement-placeholder__orbit">
            <span />
            <span />
            <span />
          </div>
          <strong>The clearing split will appear here</strong>
          <p>
            Close the batch, then submit the approved deterministic solution.
          </p>
        </div>
      ) : (
        <>
          <div className="settlement-hero-metric">
            <span>Matched away from the AMM</span>
            <strong>{formatPercent(result.directMatchPercent)}</strong>
            <small>
              {formatCompactUsd(result.directMatchNotional)} of{" "}
              {formatCompactUsd(result.totalNotional)} notional matched directly
            </small>
          </div>

          <div
            className="split-bar"
            aria-label={`${formatPercent(result.directMatchPercent)} direct match and ${formatPercent(result.residualPercent)} residual`}
          >
            <div style={{ width: `${result.directMatchPercent}%` }}>
              <span>Direct match</span>
              <strong>{formatPercent(result.directMatchPercent)}</strong>
            </div>
            {result.residualPercent > 0 && (
              <div style={{ width: `${result.residualPercent}%` }}>
                <span>Residual</span>
                <strong>{formatPercent(result.residualPercent)}</strong>
              </div>
            )}
          </div>

          <div className="flow-grid">
            <div className="flow-path flow-path--direct">
              <span className="flow-path__icon">
                <GitBranch size={20} />
              </span>
              <div>
                <span>Peer-to-peer path</span>
                <strong>{formatCompactUsd(result.directMatchNotional)}</strong>
                <small>Cleared at {result.uniformPrice}</small>
              </div>
              <BadgeCheck size={22} aria-label="Direct match verified" />
            </div>
            <div className="flow-path flow-path--residual">
              <span className="flow-path__icon">
                <Route size={20} />
              </span>
              <div>
                <span>Uniswap v4 path</span>
                <strong>{formatAmount(result.residualInput)}</strong>
                <small>
                  {result.residualNotional
                    ? `${formatAmount(result.realizedOutput)} realized output`
                    : "No pool swap required"}
                </small>
              </div>
              <ArrowRight size={22} aria-hidden="true" />
            </div>
          </div>

          <dl className="settlement-proof-grid">
            <div>
              <dt>Uniform price</dt>
              <dd>{result.uniformPrice}</dd>
            </div>
            <div>
              <dt>Protocol dust</dt>
              <dd>{formatAmount(result.protocolDust)}</dd>
            </div>
            <div>
              <dt>Pool movement</dt>
              <dd>{result.poolMoved ? "Residual only" : "None"}</dd>
            </div>
            <div>
              <dt>Unresolved deltas</dt>
              <dd className="proof-neutral">
                {result.zeroUnresolvedDeltas ? "0 · 0" : "Review required"}
              </dd>
            </div>
          </dl>
        </>
      )}
    </section>
  );
}

function ClaimPanel({
  snapshot,
  recipient,
  setRecipient,
  claim,
  pending,
}: {
  snapshot: AuraSnapshot;
  recipient: string;
  setRecipient: (value: string) => void;
  claim: () => void;
  pending: boolean;
}) {
  const alice = snapshot.claims[0];
  return (
    <section className="panel claim-panel" aria-labelledby="claim-title">
      <div className="panel__header">
        <div>
          <div className="section-kicker">
            <WalletCards size={14} aria-hidden="true" /> Sovereign pull
          </div>
          <h2 id="claim-title">Claim output</h2>
        </div>
        <ShieldCheck
          size={22}
          className="emerald"
          aria-label="Claim protected"
        />
      </div>

      {!alice ? (
        <div className="empty-state empty-state--compact">
          <CircleDollarSign size={28} />
          <strong>No claimable output yet</strong>
          <p>
            Settlement credits the internal ledger before any user transfer.
          </p>
        </div>
      ) : (
        <div className="claim-content">
          <div className="claim-balance">
            <span>{alice.accountLabel}'s claimable output</span>
            <strong>{formatAmount(alice.amount)}</strong>
            <small>Backed by a hook-owned ERC-6909 claim</small>
          </div>
          <label htmlFor="claim-recipient">Send claimed tokens to</label>
          <div className="address-input">
            <input
              id="claim-recipient"
              value={recipient}
              onChange={(event) => setRecipient(event.target.value)}
              aria-describedby="recipient-help"
              disabled={alice.status === "claimed" || pending}
            />
            <span>
              {recipient === alice.account ? "Self" : "Chosen recipient"}
            </span>
          </div>
          <p id="recipient-help">
            Only the credited account can claim, but it controls the final
            recipient.
          </p>
          <button
            className="primary-button primary-button--full"
            type="button"
            onClick={claim}
            disabled={alice.status === "claimed" || pending}
          >
            {pending ? (
              <>
                <RefreshCw className="spin" size={17} /> Claim pending
              </>
            ) : alice.status === "claimed" ? (
              <>
                <Check size={17} /> Output claimed
              </>
            ) : (
              <>
                <WalletCards size={17} /> Claim {formatAmount(alice.amount)}
              </>
            )}
          </button>
          <div className="claim-safety">
            <LockKeyhole size={16} />
            <span>
              No output is pushed during settlement. A failed recipient affects
              only this claim.
            </span>
          </div>
        </div>
      )}
    </section>
  );
}

function EvidenceDrawer({
  snapshot,
  mode,
}: {
  snapshot: AuraSnapshot;
  mode: string;
}) {
  const evidenceNotice =
    mode === "Local simulation"
      ? "These are reproducible local trace identifiers, not public transaction hashes or Blockscout evidence."
      : mode === "Anvil evidence"
        ? "These identifiers come from a local Anvil chain, not a public block explorer."
        : "This source reports Unichain Sepolia evidence. Verify each identifier against the configured public explorer.";
  return (
    <details className="evidence-drawer panel">
      <summary>
        <div>
          <span className="section-kicker">
            <BadgeCheck size={14} /> Proof package
          </span>
          <strong>Inspect deterministic evidence</strong>
        </div>
        <div>
          <StatusPill tone="neutral">{mode}</StatusPill>
          <ChevronDown size={18} className="chevron" />
        </div>
      </summary>
      <div className="evidence-drawer__body">
        <div className="evidence-notice">
          <AlertCircle size={17} />
          <span>{evidenceNotice}</span>
        </div>
        <dl>
          {snapshot.evidence.map((item) => (
            <div key={`${item.label}-${item.value}`}>
              <dt>
                {item.label}
                <span>{item.kind}</span>
              </dt>
              <dd>{item.value}</dd>
            </div>
          ))}
        </dl>
      </div>
    </details>
  );
}

function ActionConsole({
  snapshot,
  busy,
  runAction,
  scenario,
  changeScenario,
}: {
  snapshot: AuraSnapshot;
  busy: ActionName | null;
  runAction: (action: ActionName) => void;
  scenario: ScenarioKind;
  changeScenario: (scenario: ScenarioKind) => void;
}) {
  const phase = snapshot.phase;
  const batchWindow = snapshot.batchWindow;
  const elapsedBlocks = batchWindow
    ? batchWindow.currentBlock - batchWindow.openedAtBlock
    : 0;
  const firstEligibleBlock = batchWindow
    ? batchWindow.openedAtBlock + batchWindow.maxWindowBlocks + 1
    : 0;
  const closeEligible = Boolean(
    batchWindow && batchWindow.currentBlock >= firstEligibleBlock,
  );
  const actions: Array<{
    name: ActionName;
    label: string;
    helper: string;
    icon: LucideIcon;
    enabled: boolean;
  }> = [
    {
      name: "load",
      label: "Load demo orders",
      helper: "Park both exact-input intents",
      icon: Play,
      enabled: phase === "empty",
    },
    {
      name: "close",
      label: "Close batch",
      helper: closeEligible
        ? `${elapsedBlocks} blocks elapsed · closure eligible`
        : "Waiting for the strict intake boundary",
      icon: LockKeyhole,
      enabled: phase === "parked" && closeEligible,
    },
    {
      name: "settle",
      label: "Submit solution",
      helper: "Run the approved local fixture",
      icon: Sparkles,
      enabled: phase === "closed",
    },
  ];
  return (
    <section className="action-console" aria-labelledby="controls-title">
      <div className="action-console__header">
        <div>
          <span className="section-kicker">
            <Gauge size={14} /> Demo controls
          </span>
          <h2 id="controls-title">One clear path. No hidden steps.</h2>
        </div>
        <div className="scenario-toggle" aria-label="Settlement scenario">
          <button
            type="button"
            className={scenario === "residual" ? "is-active" : ""}
            onClick={() => changeScenario("residual")}
            disabled={phase !== "empty" || busy !== null}
          >
            Residual batch
          </button>
          <button
            type="button"
            className={scenario === "perfect-cow" ? "is-active" : ""}
            onClick={() => changeScenario("perfect-cow")}
            disabled={phase !== "empty" || busy !== null}
          >
            Perfect CoW
          </button>
        </div>
      </div>
      {batchWindow && phase === "parked" ? (
        <div className="batch-window-proof" role="status" aria-live="polite">
          <span className="batch-window-proof__icon" aria-hidden="true">
            <Clock3 size={17} />
          </span>
          <span>
            <small>Deterministic intake window</small>
            <strong>{elapsedBlocks} local blocks elapsed</strong>
          </span>
          <span className="batch-window-proof__blocks">
            Opened {batchWindow.openedAtBlock.toLocaleString()} · closure
            eligible at block {firstEligibleBlock.toLocaleString()}
          </span>
          <StatusPill tone={closeEligible ? "success" : "gold"}>
            {closeEligible ? "Boundary passed" : "Window active"}
          </StatusPill>
        </div>
      ) : null}
      <div className="action-list">
        {actions.map((action, index) => {
          const Icon = action.icon;
          const complete = PHASE_RANK[phase] > index;
          const isBusy = busy === action.name;
          return (
            <button
              key={action.name}
              type="button"
              aria-label={isBusy ? `${action.label}, pending` : action.label}
              onClick={() => runAction(action.name)}
              disabled={!action.enabled || busy !== null}
              className={complete ? "is-complete" : ""}
            >
              <span className="action-list__number">0{index + 1}</span>
              <span className="action-list__icon">
                {isBusy ? (
                  <RefreshCw className="spin" size={18} />
                ) : complete ? (
                  <Check size={18} />
                ) : (
                  <Icon size={18} />
                )}
              </span>
              <span>
                <strong>{isBusy ? `${action.label}…` : action.label}</strong>
                <small>{action.helper}</small>
              </span>
              <ArrowRight size={18} aria-hidden="true" />
            </button>
          );
        })}
      </div>
      <button
        type="button"
        className="reset-button"
        onClick={() => runAction("reset")}
        disabled={busy !== null || phase === "empty"}
      >
        <RefreshCw size={15} /> Reset deterministic demo
      </button>
    </section>
  );
}

function ConnectionBanner({ preview }: { preview: PreviewMode }) {
  if (preview === "normal" || preview === "claim-error") return null;
  const content = {
    disconnected: {
      icon: Unplug,
      title: "Wallet disconnected",
      body: "The deterministic demo remains available. Connect a wallet only when a verified testnet adapter is configured.",
    },
    "wrong-network": {
      icon: Network,
      title: "Wrong network",
      body: "Switch to the configured Aura network before attempting a live contract interaction.",
    },
    unavailable: {
      icon: XCircle,
      title: "Data source unavailable",
      body: "No custody is at risk. Retry the local fixture or continue with the recorded Anvil fallback.",
    },
  }[preview];
  if (!content) return null;
  const Icon = content.icon;
  return (
    <div className="connection-banner" role="alert">
      <Icon size={19} />
      <div>
        <strong>{content.title}</strong>
        <span>{content.body}</span>
      </div>
    </div>
  );
}

export default function App({
  dataSource = localAuraDataSource,
  previewMode,
}: AppProps) {
  const preview = previewMode ?? getPreviewMode();
  const [scenario, setScenario] = useState<ScenarioKind>("residual");
  const [snapshot, setSnapshot] = useState<AuraSnapshot | null>(null);
  const [busy, setBusy] = useState<ActionName | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [reloadToken, setReloadToken] = useState(0);
  const [notice, setNotice] = useState<{
    tone: "success" | "error";
    message: string;
  } | null>(null);
  const [recipient, setRecipient] = useState("");

  useEffect(() => {
    let active = true;
    if (preview === "unavailable")
      return () => {
        active = false;
      };
    setLoadError(null);
    dataSource
      .getInitialSnapshot(scenario)
      .then((value) => {
        if (!active) return;
        setSnapshot(value);
        setBusy(null);
      })
      .catch((error: unknown) => {
        if (!active) return;
        setLoadError(
          error instanceof Error
            ? error.message
            : "The evidence source could not be loaded.",
        );
        setBusy(null);
      });
    return () => {
      active = false;
    };
  }, [dataSource, preview, reloadToken, scenario]);

  useEffect(() => {
    const claim = snapshot?.claims[0];
    if (!claim) return;
    setRecipient(
      preview === "claim-error"
        ? "0x000000000000000000000000000000000000dEaD"
        : claim.recipient,
    );
  }, [preview, snapshot?.claims]);

  const displaySnapshot = useMemo(() => {
    if (!snapshot) return null;
    if (preview === "disconnected" || preview === "wrong-network") {
      return { ...snapshot, pool: { ...snapshot.pool, connection: preview } };
    }
    return snapshot;
  }, [preview, snapshot]);

  async function runAction(action: ActionName) {
    if (!snapshot || busy) return;
    setBusy(action);
    setNotice(null);
    try {
      let next = snapshot;
      if (action === "load") next = await dataSource.parkDemoOrders(snapshot);
      if (action === "close") next = await dataSource.closeBatch(snapshot);
      if (action === "settle") next = await dataSource.settleBatch(snapshot);
      if (action === "claim")
        next = await dataSource.claimOutput(
          snapshot,
          snapshot.claims[0]?.account ?? "",
          recipient,
        );
      if (action === "reset") next = await dataSource.reset(scenario);
      setSnapshot(next);
      setNotice({
        tone: "success",
        message:
          action === "reset"
            ? "The deterministic demo is ready to replay."
            : `${action[0].toUpperCase()}${action.slice(1)} completed successfully.`,
      });
    } catch (error: unknown) {
      setNotice({
        tone: "error",
        message:
          error instanceof Error
            ? error.message
            : "The action failed safely. No local state was changed.",
      });
    } finally {
      setBusy(null);
    }
  }

  async function changeScenario(nextScenario: ScenarioKind) {
    if (busy || snapshot?.phase !== "empty") return;
    setBusy("reset");
    setSnapshot(null);
    setLoadError(null);
    setScenario(nextScenario);
    setNotice(null);
  }

  if (!displaySnapshot) {
    const retryLoad = () => {
      setLoadError(null);
      setBusy("reset");
      setReloadToken((value) => value + 1);
    };
    return (
      <main className="loading-screen">
        <AuraMark />
        {preview === "unavailable" ? (
          <div className="loading-error" role="alert">
            <XCircle size={24} />
            <strong>Local evidence source unavailable</strong>
            <p>
              Refresh the fixture or continue with the documented Anvil
              fallback. No assets are affected.
            </p>
          </div>
        ) : loadError ? (
          <div className="loading-error" role="alert">
            <XCircle size={24} />
            <strong>Evidence source could not be loaded</strong>
            <p>{loadError} No local state or custody was changed.</p>
            <button
              type="button"
              className="primary-button"
              onClick={retryLoad}
            >
              <RefreshCw size={15} /> Retry evidence source
            </button>
          </div>
        ) : (
          <>
            <span className="loading-ring" />
            <strong>Preparing Aura's deterministic evidence…</strong>
          </>
        )}
      </main>
    );
  }

  const result = displaySnapshot.settlement;
  const environment =
    dataSource.mode === "Local simulation"
      ? {
          network: "Deterministic fixture",
          wallet: "Demo wallet ready",
          footer:
            "Local evidence only · No public transaction was signed or broadcast.",
        }
      : dataSource.mode === "Anvil evidence"
        ? {
            network: "Local Anvil",
            wallet: "Anvil adapter ready",
            footer:
              "Local Anvil evidence · No public transaction was broadcast.",
          }
        : {
            network: "Unichain Sepolia",
            wallet: "Read-only evidence",
            footer:
              "Public testnet evidence · Verify identifiers before relying on them.",
          };
  const phaseLabel =
    displaySnapshot.phase === "empty"
      ? "Ready to begin"
      : displaySnapshot.phase;
  const directPercent = result?.directMatchPercent ?? 0;

  return (
    <div className="app-shell">
      <header className="topbar">
        <a
          href="#main"
          className="brand"
          aria-label="Aura Settlement Console home"
        >
          <AuraMark />
          <span>
            <strong>Aura</strong>
            <small>Settlement Console</small>
          </span>
        </a>
        <nav aria-label="Environment status">
          <StatusPill tone="gold">
            <Activity size={12} /> {dataSource.mode}
          </StatusPill>
          <span className="network-label">
            <span /> {environment.network}
          </span>
          <button
            type="button"
            className="wallet-status"
            aria-label={environment.wallet}
          >
            <WalletCards size={16} /> {environment.wallet}
          </button>
        </nav>
      </header>

      <ConnectionBanner preview={preview} />

      <main id="main">
        <section className="hero-section">
          <div className="hero-section__copy">
            <div className="eyebrow">
              <span>Coincidence of Wants</span>
              <i />
              <span>Uniswap v4</span>
            </div>
            <h1>
              Settle together.
              <br />
              <em>Move only the difference.</em>
            </h1>
            <p>
              Aura matches opposing intent first, routes only the residual
              through the pool, and leaves every output sovereignly claimable.
            </p>
            <div className="hero-section__badges">
              <StatusPill tone="success">
                <ShieldCheck size={13} /> Fully backed
              </StatusPill>
              <StatusPill>
                <LockKeyhole size={13} /> Exact-input only
              </StatusPill>
              <StatusPill>
                <Route size={13} /> One residual max
              </StatusPill>
            </div>
          </div>
          <div
            className="hero-visual"
            aria-label={`${directPercent}% of this batch matched directly`}
          >
            <div className="hero-visual__halo hero-visual__halo--one" />
            <div className="hero-visual__halo hero-visual__halo--two" />
            <div className="hero-visual__center">
              <span>{result ? formatPercent(directPercent) : "CoW"}</span>
              <small>{result ? "direct match" : "match first"}</small>
            </div>
            <div className="hero-visual__node hero-visual__node--left">
              <span>$</span>
              <small>USDC intent</small>
            </div>
            <div className="hero-visual__node hero-visual__node--right">
              <span>Ξ</span>
              <small>WETH intent</small>
            </div>
            <div className="hero-visual__residual">
              <Route size={15} />
              <span>
                {result
                  ? formatPercent(result.residualPercent)
                  : "residual only"}
              </span>
            </div>
          </div>
        </section>

        <section className="metrics-strip" aria-label="Aura batch highlights">
          <Metric
            label="Current state"
            value={phaseLabel}
            helper="One bounded batch"
            icon={Orbit}
          />
          <Metric
            label="Uniform price"
            value={result?.uniformPrice ?? "Derived on close"}
            helper="Never selected by the UI"
            icon={Gauge}
          />
          <Metric
            label="Curve interaction"
            value={
              result ? (result.poolMoved ? "Residual only" : "None") : "Waiting"
            }
            helper="Parking remains neutral"
            icon={Route}
          />
          <Metric
            label="Custody proof"
            value={result?.zeroUnresolvedDeltas ? "0 · 0 deltas" : "Pending"}
            helper="ERC-6909 backed"
            icon={ShieldCheck}
          />
        </section>

        <StageRail phase={displaySnapshot.phase} />

        <div className="dashboard-grid dashboard-grid--top">
          <PoolProofCard snapshot={displaySnapshot} mode={dataSource.mode} />
          <ActionConsole
            snapshot={displaySnapshot}
            busy={busy}
            runAction={runAction}
            scenario={scenario}
            changeScenario={changeScenario}
          />
        </div>

        {notice && (
          <div
            className={`action-notice action-notice--${notice.tone}`}
            role={notice.tone === "error" ? "alert" : "status"}
            aria-live="polite"
          >
            {notice.tone === "error" ? (
              <AlertCircle size={18} />
            ) : (
              <CheckCircle2 size={18} />
            )}
            <span>{notice.message}</span>
          </div>
        )}

        <OrderBoard
          orders={displaySnapshot.orders}
          phase={displaySnapshot.phase}
        />

        <div className="dashboard-grid dashboard-grid--bottom">
          <SettlementVisual snapshot={displaySnapshot} />
          <ClaimPanel
            snapshot={displaySnapshot}
            recipient={recipient}
            setRecipient={setRecipient}
            claim={() => runAction("claim")}
            pending={busy === "claim"}
          />
        </div>

        <EvidenceDrawer snapshot={displaySnapshot} mode={dataSource.mode} />
      </main>

      <footer>
        <div>
          <AuraMark />
          <span>
            <strong>Aura Core</strong>
            <small>One pool. One price. One residual.</small>
          </span>
        </div>
        <p>{environment.footer}</p>
        <span>Issue #13 · Commit 4198d1e</span>
      </footer>
    </div>
  );
}
