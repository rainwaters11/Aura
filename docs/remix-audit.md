# Remix audit record

## Compiler configuration

The manual Remix audit uses Solidity 0.8.30, the Cancun EVM target, optimizer
enabled with 200 runs, and `via_ir` disabled. These settings match the locked
Foundry profile.

## AuraRouter import correction

The original Remix compilation of `AuraRouter` failed because `SwapParams` was
only available through an indirect combined import from `IPoolManager.sol`.
PR #32 corrected that portability failure by retaining the direct
`IPoolManager` interface import and explicitly importing `SwapParams` from
`types/PoolOperation.sol`. The correction was import-only and preserved both
the `AuraRouter` creation bytecode and runtime bytecode.

## Exact-head status

The manual Remix audit **must be rerun at the final updated exact head before
approval**. Earlier compilation or bytecode-parity evidence is predecessor
evidence only and cannot approve a later commit.
