import { describe, expect, it } from "vitest";

import { createLocalAuraDataSource } from "./localAuraDataSource";

describe("local Aura data source", () => {
  it("replays the residual settlement lifecycle deterministically", async () => {
    const source = createLocalAuraDataSource(0);
    let snapshot = await source.getInitialSnapshot("residual");
    expect(snapshot.phase).toBe("empty");
    expect(snapshot.pool.after).toEqual(snapshot.pool.before);

    snapshot = await source.parkDemoOrders(snapshot);
    expect(snapshot.orders).toHaveLength(2);
    expect(snapshot.orders.map((order) => order.direction)).toEqual([
      "token0-to-token1",
      "token1-to-token0",
    ]);

    snapshot = await source.closeBatch(snapshot);
    snapshot = await source.settleBatch(snapshot);

    expect(snapshot.settlement).toMatchObject({
      directMatchPercent: 88.9,
      residualPercent: 11.1,
      zeroUnresolvedDeltas: true,
      poolMoved: true,
    });
    expect(snapshot.claims.map((claim) => claim.status)).toEqual([
      "available",
      "available",
    ]);
    expect(snapshot.orders.map((order) => order.status)).toEqual([
      "SETTLED",
      "SETTLED",
    ]);
    expect(snapshot.pool.after).not.toEqual(snapshot.pool.before);
  });

  it("represents a perfect CoW without pool movement", async () => {
    const source = createLocalAuraDataSource(0);
    let snapshot = await source.getInitialSnapshot("perfect-cow");
    snapshot = await source.parkDemoOrders(snapshot);
    snapshot = await source.closeBatch(snapshot);
    snapshot = await source.settleBatch(snapshot);

    expect(snapshot.settlement?.directMatchPercent).toBe(100);
    expect(snapshot.settlement?.residualInput.value).toBe(0);
    expect(snapshot.pool.after).toEqual(snapshot.pool.before);
  });

  it("keeps a failed recipient claim available and isolated", async () => {
    const source = createLocalAuraDataSource(0);
    let snapshot = await source.getInitialSnapshot("residual");
    snapshot = await source.parkDemoOrders(snapshot);
    snapshot = await source.closeBatch(snapshot);
    snapshot = await source.settleBatch(snapshot);

    await expect(
      source.claimOutput(
        snapshot,
        snapshot.claims[0].account,
        "0x000000000000000000000000000000000000dEaD",
      ),
    ).rejects.toThrow("Alice’s claim remains fully available");
    expect(snapshot.claims.map((claim) => claim.status)).toEqual([
      "available",
      "available",
    ]);
  });

  it("marks only the selected account claimed and rejects replay", async () => {
    const source = createLocalAuraDataSource(0);
    let snapshot = await source.getInitialSnapshot("residual");
    snapshot = await source.parkDemoOrders(snapshot);
    snapshot = await source.closeBatch(snapshot);
    snapshot = await source.settleBatch(snapshot);
    const account = snapshot.claims[0].account;

    snapshot = await source.claimOutput(snapshot, account, account);
    expect(snapshot.claims.map((claim) => claim.status)).toEqual([
      "claimed",
      "available",
    ]);
    expect(snapshot.orders.map((order) => order.status)).toEqual([
      "SETTLED",
      "SETTLED",
    ]);
    await expect(
      source.claimOutput(snapshot, account, account),
    ).rejects.toThrow("no available output");
  });

  it("rejects malformed and zero claim recipients", async () => {
    const source = createLocalAuraDataSource(0);
    let snapshot = await source.getInitialSnapshot("residual");
    snapshot = await source.parkDemoOrders(snapshot);
    snapshot = await source.closeBatch(snapshot);
    snapshot = await source.settleBatch(snapshot);
    const account = snapshot.claims[0].account;

    await expect(
      source.claimOutput(
        snapshot,
        account,
        "0xgggggggggggggggggggggggggggggggggggggggg",
      ),
    ).rejects.toThrow("valid nonzero recipient");
    await expect(
      source.claimOutput(
        snapshot,
        account,
        "0x0000000000000000000000000000000000000000",
      ),
    ).rejects.toThrow("valid nonzero recipient");
    expect(snapshot.claims[0].status).toBe("available");
  });
});
