import {
  cleanup,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";

import App from "./App";
import { createLocalAuraDataSource } from "./data/localAuraDataSource";

afterEach(cleanup);

async function renderReady(previewMode: "normal" | "claim-error" = "normal") {
  const user = userEvent.setup();
  render(
    <App dataSource={createLocalAuraDataSource(0)} previewMode={previewMode} />,
  );
  await screen.findByRole("button", { name: /load demo orders/i });
  return user;
}

async function advanceToSettlement(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("button", { name: /load demo orders/i }));
  await screen.findByText("Alice");
  await user.click(screen.getByRole("button", { name: /^close batch/i }));
  await waitFor(() =>
    expect(
      screen.getByRole("button", { name: /^submit solution/i }),
    ).toBeEnabled(),
  );
  await user.click(screen.getByRole("button", { name: /^submit solution/i }));
  await screen.findByText("88.9%", {
    selector: ".settlement-hero-metric strong",
  });
}

describe("Aura Settlement Console", () => {
  it("starts with a clear empty state and accessible controls", async () => {
    await renderReady();
    expect(
      screen.getByRole("heading", { name: /settle together/i }),
    ).toBeInTheDocument();
    expect(screen.getByText("No orders parked yet")).toBeInTheDocument();
    expect(screen.getByText("Awaiting orders")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /^close batch/i }),
    ).toBeDisabled();
    expect(
      screen.getByRole("button", { name: /^submit solution/i }),
    ).toBeDisabled();
  });

  it("completes the full judge flow through sovereign claim success", async () => {
    const user = await renderReady();
    await advanceToSettlement(user);

    expect(
      screen.getByText("Only the residual moved the curve"),
    ).toBeInTheDocument();
    expect(screen.getByText("0 · 0")).toBeInTheDocument();
    const claimPanel = screen
      .getByRole("heading", { name: "Claim output" })
      .closest("section");
    expect(claimPanel).not.toBeNull();
    await user.click(
      within(claimPanel!).getByRole("button", { name: /claim 4 weth/i }),
    );
    await screen.findByRole("button", { name: /output claimed/i });
    expect(
      screen.getByText(/Claim completed successfully/i),
    ).toBeInTheDocument();
  });

  it("switches to a perfect CoW fixture and proves no pool movement", async () => {
    const user = await renderReady();
    await user.click(screen.getByRole("button", { name: "Perfect CoW" }));
    await user.click(
      await screen.findByRole("button", { name: /load demo orders/i }),
    );
    await user.click(
      await screen.findByRole("button", { name: /^close batch/i }),
    );
    await user.click(
      await screen.findByRole("button", { name: /^submit solution/i }),
    );

    await screen.findByText("100%", {
      selector: ".settlement-hero-metric strong",
    });
    expect(
      screen.getByText("Perfect CoW: curve untouched"),
    ).toBeInTheDocument();
    expect(screen.getByText("No pool swap required")).toBeInTheDocument();
  });

  it("renders clear wrong-network guidance without hiding the local demo", async () => {
    render(
      <App
        dataSource={createLocalAuraDataSource(0)}
        previewMode="wrong-network"
      />,
    );
    expect(await screen.findByRole("alert")).toHaveTextContent("Wrong network");
    expect(
      screen.getByRole("button", { name: /load demo orders/i }),
    ).toBeEnabled();
  });

  it("shows a safe unavailable-source recovery state", () => {
    render(
      <App
        dataSource={createLocalAuraDataSource(0)}
        previewMode="unavailable"
      />,
    );
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Local evidence source unavailable",
    );
    expect(screen.getByText(/No assets are affected/i)).toBeInTheDocument();
  });

  it("keeps the claim available when a recipient rejects transfer", async () => {
    const user = await renderReady("claim-error");
    await advanceToSettlement(user);
    await user.click(screen.getByRole("button", { name: /claim 4 weth/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Alice’s claim remains fully available",
    );
    expect(screen.getByRole("button", { name: /claim 4 weth/i })).toBeEnabled();
  });

  it("labels batch membership according to the actual lifecycle", async () => {
    const user = await renderReady();
    await user.click(screen.getByRole("button", { name: /load demo orders/i }));
    expect(await screen.findByText("Intake open")).toBeInTheDocument();
    expect(screen.queryByText("Frozen membership")).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /close batch/i }));
    expect(await screen.findByText("Frozen membership")).toBeInTheDocument();
  });

  it("locks the stale fixture while a scenario reloads", async () => {
    const user = userEvent.setup();
    render(
      <App dataSource={createLocalAuraDataSource(30)} previewMode="normal" />,
    );
    await screen.findByRole("button", { name: /load demo orders/i });

    await user.click(screen.getByRole("button", { name: "Perfect CoW" }));
    expect(
      screen.queryByRole("button", { name: /load demo orders/i }),
    ).not.toBeInTheDocument();
    expect(
      screen.getByText(/Preparing Aura's deterministic evidence/i),
    ).toBeInTheDocument();
    expect(
      await screen.findByRole("button", { name: /load demo orders/i }),
    ).toBeEnabled();
  });

  it("describes evidence according to the injected source", async () => {
    const source = {
      ...createLocalAuraDataSource(0),
      mode: "Unichain Sepolia evidence" as const,
    };
    render(<App dataSource={source} previewMode="normal" />);
    await screen.findByRole("button", { name: /load demo orders/i });

    expect(
      screen.getByText(/This source reports Unichain Sepolia evidence/i),
    ).toBeInTheDocument();
    expect(
      screen.getAllByText("Unichain Sepolia evidence").length,
    ).toBeGreaterThan(0);
    expect(
      screen.getByRole("button", { name: "Read-only evidence" }),
    ).toBeInTheDocument();
    expect(screen.getByText("Sepolia source ready")).toBeInTheDocument();
    expect(
      screen.getByText(/Public testnet evidence · Verify identifiers/i),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(/These are reproducible local trace identifiers/i),
    ).not.toBeInTheDocument();
    expect(screen.queryByText(/Local evidence only/i)).not.toBeInTheDocument();

    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /load demo orders/i }));
    await user.click(screen.getByRole("button", { name: /close batch/i }));
    await user.click(screen.getByRole("button", { name: /submit solution/i }));
    expect(
      await screen.findByText(
        "Verified by Unichain Sepolia execution evidence.",
      ),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(/deterministic local accounting evidence/i),
    ).not.toBeInTheDocument();
  });

  it("surfaces scenario reload failures and recovers on retry", async () => {
    const source = createLocalAuraDataSource(0);
    const residual = await source.getInitialSnapshot("residual");
    const perfectCow = await source.getInitialSnapshot("perfect-cow");
    const getInitialSnapshot = vi
      .fn()
      .mockResolvedValueOnce(residual)
      .mockRejectedValueOnce(new Error("The fixture adapter is offline."))
      .mockResolvedValueOnce(perfectCow);
    const recoverableSource = { ...source, getInitialSnapshot };
    const user = userEvent.setup();
    render(<App dataSource={recoverableSource} previewMode="normal" />);
    await screen.findByRole("button", { name: /load demo orders/i });

    await user.click(screen.getByRole("button", { name: "Perfect CoW" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "The fixture adapter is offline",
    );
    await user.click(
      screen.getByRole("button", { name: /retry evidence source/i }),
    );

    expect(
      await screen.findByRole("button", { name: /load demo orders/i }),
    ).toBeEnabled();
    expect(getInitialSnapshot).toHaveBeenCalledTimes(3);
  });
});
