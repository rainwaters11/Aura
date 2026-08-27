import type { AuraDataSource } from "../types/aura";

/**
 * Reserved adapter seam for Issue #15/16 deployment evidence.
 * No signer, RPC credential, or production authority is loaded by the Issue #13 client.
 */
export interface AnvilAuraDataSource extends AuraDataSource {
  readonly rpcUrl: "http://127.0.0.1:8545";
}
