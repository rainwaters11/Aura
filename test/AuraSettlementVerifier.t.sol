// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {AuraHook} from "../src/AuraHook.sol";
import {AuraRouter} from "../src/AuraRouter.sol";
import {AuraSettlementVerifier} from "../src/AuraSettlementVerifier.sol";
import {IAuraSettlementVerifier} from "../src/interfaces/IAuraSettlementVerifier.sol";
import {AuraClearingMath} from "../src/libraries/AuraClearingMath.sol";
import {BatchSolution, ParkedOrder, OrderStatus, BatchStatus} from "../src/types/AuraTypes.sol";
import {AuraParkingBase} from "./AuraParking.t.sol";

contract VerifierSourceHarness {
    PoolId public auraPoolId;
    mapping(uint64 => BatchStatus) public batchStatus;
    mapping(uint64 => uint64) public closedAtTimestamp;
    mapping(bytes32 => bool) public usedSolutions;
    mapping(bytes32 => ParkedOrder) public orders;
    mapping(uint64 => bytes32[]) private _ids;

    constructor(PoolId poolId) {
        auraPoolId = poolId;
    }

    function configure(uint64 batchId, bytes32[] memory ids, ParkedOrder[] memory parked) external {
        batchStatus[batchId] = BatchStatus.CLOSED;
        closedAtTimestamp[batchId] = uint64(block.timestamp);
        for (uint256 i; i < ids.length; ++i) {
            _ids[batchId].push(ids[i]);
            orders[ids[i]] = parked[i];
        }
    }

    function setPoolId(PoolId poolId) external {
        auraPoolId = poolId;
    }

    function setStatus(uint64 batchId, BatchStatus status) external {
        batchStatus[batchId] = status;
    }

    function setUsed(bytes32 solutionHash) external {
        usedSolutions[solutionHash] = true;
    }

    function batchOrderIds(uint64 batchId) external view returns (bytes32[] memory) {
        return _ids[batchId];
    }

    function validate(IAuraSettlementVerifier verifier, BatchSolution calldata solution)
        external
        view
        returns (bytes4)
    {
        return verifier.validate(solution);
    }
}

contract AuraSettlementVerifierTest is AuraParkingBase {
    using CurrencyLibrary for Currency;

    uint64 private constant VERIFY_BATCH = 77;
    AuraSettlementVerifier private isolatedVerifier;
    VerifierSourceHarness private source;

    function setUp() public override {
        super.setUp();
        isolatedVerifier = new AuraSettlementVerifier();
        source = new VerifierSourceHarness(PoolId.wrap(keccak256("verifier-pool")));
    }

    function test_verifierPullsTrustedStateAndMatchesLibraryValidation() public {
        BatchSolution memory solution = _fixture();
        bytes4 result = source.validate(isolatedVerifier, solution);
        assertEq(result, isolatedVerifier.VALID_SOLUTION());
    }

    function test_verifierHasNoStorageAndCannotMutateSourceOrPoolManager() public {
        BatchSolution memory solution = _fixture();
        bytes32 slotBefore = vm.load(address(isolatedVerifier), bytes32(0));
        uint256 hookToken0Claims = poolManager.balanceOf(address(hook), currency0.toId());

        source.validate(isolatedVerifier, solution);

        assertEq(vm.load(address(isolatedVerifier), bytes32(0)), slotBefore);
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), hookToken0Claims);
        assertFalse(source.usedSolutions(solution.solutionHash));
    }

    function test_rejectsMaliciousSourceStateAndWrongPoolDomain() public {
        BatchSolution memory solution = _fixture();
        source.setStatus(VERIFY_BATCH, BatchStatus.READY);
        vm.expectRevert(AuraSettlementVerifier.BatchNotClosed.selector);
        source.validate(isolatedVerifier, solution);

        source.setStatus(VERIFY_BATCH, BatchStatus.CLOSED);
        source.setPoolId(PoolId.wrap(keccak256("wrong-pool")));
        vm.expectRevert(AuraClearingMath.InvalidSolutionHash.selector);
        source.validate(isolatedVerifier, solution);
    }

    function test_rejectsReplayAndMalformedSolution() public {
        BatchSolution memory solution = _fixture();
        source.setUsed(solution.solutionHash);
        vm.expectRevert(AuraClearingMath.SolutionAlreadyUsed.selector);
        source.validate(isolatedVerifier, solution);

        solution = _fixtureForNewSource();
        solution.payouts = new uint128[](1);
        vm.expectRevert(AuraClearingMath.ArrayLengthMismatch.selector);
        source.validate(isolatedVerifier, solution);
    }

    function test_hookRejectsZeroVerifier() public {
        _assertInvalidVerifier(IAuraSettlementVerifier(address(0)));
    }

    function test_hookRejectsVerifierWithoutCode() public {
        _assertInvalidVerifier(IAuraSettlementVerifier(address(0xBEEF)));
    }

    function _assertInvalidVerifier(IAuraSettlementVerifier invalidVerifier) private {
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory args = abi.encode(
            poolManager,
            predictedRouter,
            currency0,
            currency1,
            uint24(3000),
            int24(60),
            invalidVerifier,
            address(this),
            address(this),
            address(this),
            Constants.SQRT_PRICE_1_1
        );
        (address mined, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(AuraHook).creationCode, args);
        AuraRouter otherRouter = new AuraRouter(poolManager, PoolKey(currency0, currency1, 3000, 60, IHooks(mined)));
        assertEq(address(otherRouter), predictedRouter);
        vm.expectRevert(AuraHook.InvalidSettlementVerifier.selector);
        new AuraHook{salt: salt}(
            poolManager,
            otherRouter,
            currency0,
            currency1,
            3000,
            60,
            invalidVerifier,
            address(this),
            address(this),
            address(this),
            Constants.SQRT_PRICE_1_1
        );
    }

    function _fixture() private returns (BatchSolution memory solution) {
        ParkedOrder[] memory parked = new ParkedOrder[](2);
        parked[0] = _order(true);
        parked[1] = _order(false);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("order-zero");
        ids[1] = keccak256("order-one");
        source.configure(VERIFY_BATCH, ids, parked);

        AuraClearingMath.Computation memory expected = AuraClearingMath.compute(parked);
        solution = BatchSolution({
            batchId: VERIFY_BATCH,
            deadline: parked[0].deadline,
            priceNumerator: expected.priceNumerator,
            priceDenominator: expected.priceDenominator,
            residualZeroForOne: expected.residualZeroForOne,
            residualAmountIn: expected.residualAmountIn,
            sqrtPriceLimitX96: 0,
            solutionHash: bytes32(0),
            orderIds: ids,
            payouts: expected.payouts
        });
        AuraClearingMath.Domain memory domain =
            AuraClearingMath.Domain(block.chainid, address(source), PoolId.unwrap(source.auraPoolId()));
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);

        AuraClearingMath.Computation memory parity = AuraClearingMath.validateSolution(
            parked, ids, keccak256(abi.encode(ids)), solution, domain, uint64(block.timestamp), false
        );
        assertEq(parity.priceNumerator, expected.priceNumerator);
        assertEq(parity.payouts[0], expected.payouts[0]);
    }

    function _fixtureForNewSource() private returns (BatchSolution memory solution) {
        source = new VerifierSourceHarness(PoolId.wrap(keccak256("verifier-pool-2")));
        return _fixture();
    }

    function _order(bool zeroForOne) private view returns (ParkedOrder memory) {
        return ParkedOrder({
            owner: address(this),
            recipient: address(this),
            batchId: VERIFY_BATCH,
            deadline: uint64(block.timestamp + 1 hours),
            nonce: zeroForOne ? 1 : 2,
            zeroForOne: zeroForOne,
            amountIn: 10 ether,
            minAmountOut: 10 ether,
            status: OrderStatus.PARKED
        });
    }
}
