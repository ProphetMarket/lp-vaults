// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ1: Create Vault for Market
// Integration tests for every scenario in this use case.
// Covers: SC-REQ6, SC-REQ7, SC-REQ8, SC-REQ9, SC-REQA, SC-RG74, SC-RG75, SC-RG76, SC-RG77,
//         SC-3WLL, SC-3WLM, SC-3WLN, SC-3WLO, SC-6HBV, SC-6HBW, SC-6HBX, SC-6HBY, SC-BZC2, SC-BZC3,
//         SC-BZC4, NFR-RER0

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {ITestConditionalTokens} from "../../fixtures/ConditionalTokensFixture.sol";
import {LPVaultFixture} from "../../fixtures/LPVaultFixture.sol";
import {MockERC20} from "../../fixtures/MockERC20.sol";

/// @dev The receiver surface under test. Declared here rather than reaching through
///      the LPVault type so these tests compile — and therefore run and fail at
///      runtime — against a vault that does not implement the hooks yet.
interface IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        returns (bytes4);
    function supportsInterface(bytes4) external view returns (bool);
}

/// @dev An unrelated ERC-1155 contract — stands in for any token contract that is not
///      the vault's own ConditionalTokens. Used to prove foreign token IDs cannot be
///      pushed into the vault via a safe transfer.
contract ForeignERC1155 {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data);
    }
}

// ──────────────────────────────────────────────
// SC-REQ6: Successful vault creation
// What: When the Oracle calls createVault with a valid marketId, tickSpacing,
//       and minimumFirstLiquidity, the factory deploys an EIP-1167 clone,
//       initializes it with all per-vault configuration, sets up USDC and CT
//       approvals on the exchange, registers the vault in vaultForMarket,
//       and emits VaultCreated.
// Why:  This is the primary entry point for the LP system — every market needs
//       a vault, and the vault must be fully configured (storage, approvals,
//       phase) before any LP can interact with it.
// Example: oracle calls createVault(marketId=0x01, tickSpacing=10, minLiq=1000,
//          conditionId, yesTokenId, noTokenId) → clone deployed at nonzero address,
//          all storage set including the identity, USDC allowance = max,
//          CT approvedForAll = true, VaultCreated event emitted.
// ──────────────────────────────────────────────
contract CreateVaultSuccessTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault impl;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    bytes32 marketId = bytes32(uint256(1));
    int24 tickSpacing = int24(10);
    uint128 minimumFirstLiquidity = uint128(1000);

    // The verified identity of the market: a prepared 2-outcome condition and its two position IDs
    bytes32 conditionId;
    uint256 yesTokenId;
    uint256 noTokenId;

    // Event re-declared so we can use vm.expectEmit on it
    event VaultCreated(bytes32 indexed marketId, address vault, uint128 minimumFirstLiquidity);

    function setUp() public {
        impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(ctf), admin, oracleAddr, operatorAddr
        );
        (conditionId, yesTokenId, noTokenId) = _prepareBinaryCondition(marketId, address(mockUsdc));
    }

    /// @dev The Oracle creates the vault with the prepared identity.
    function _create() internal returns (address vault) {
        vm.prank(oracleAddr);
        vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
    }

    // SC-REQ6: vaultForMarket returns non-zero clone address
    function test_vaultForMarketReturnsCloneAddress() public {
        address vault = _create();
        assertTrue(vault != address(0), "vault address should be non-zero");
        assertEq(factory.vaultForMarket(marketId), vault, "registry should map marketId to vault");
    }

    // SC-REQ6: clone's marketId matches
    function test_cloneMarketIdMatches() public {
        address vault = _create();
        assertEq(LPVault(vault).marketId(), marketId, "clone marketId should match");
    }

    // SC-REQ6: clone's usdc, exchange, conditionalTokens, oracle, tickSpacing, factory match factory values
    function test_cloneConfigMatchesFactoryValues() public {
        address vault = _create();
        LPVault v = LPVault(vault);
        assertEq(v.usdc(), address(mockUsdc), "usdc should match factory");
        assertEq(v.exchange(), exchangeAddr, "exchange should match factory");
        assertEq(v.conditionalTokens(), address(ctf), "conditionalTokens should match factory");
        assertEq(v.oracle(), oracleAddr, "oracle should match factory");
        assertEq(v.tickSpacing(), tickSpacing, "tickSpacing should match passed value");
        assertEq(v.factory(), address(factory), "factory should be the deploying factory");
    }

    // SC-REQ6: clone's conditionId, yesTokenId, and noTokenId match the verified identity
    function test_cloneOutcomeTokenIdentityMatches() public {
        LPVault v = LPVault(_create());
        assertEq(v.conditionId(), conditionId, "conditionId should match the passed value");
        assertEq(v.yesTokenId(), yesTokenId, "yesTokenId should be the index set 1 position ID");
        assertEq(v.noTokenId(), noTokenId, "noTokenId should be the index set 2 position ID");
    }

    // SC-REQ6: clone's minimumFirstLiquidity matches the passed value
    function test_cloneMinimumFirstLiquidityMatches() public {
        address vault = _create();
        assertEq(LPVault(vault).minimumFirstLiquidity(), minimumFirstLiquidity, "minimumFirstLiquidity should match");
    }

    // SC-REQ6, FR-REQK: the clone copies the factory's default emergency-cancel timelock (7 days on a fresh factory)
    function test_cloneEmergencyCancelTimelockMatchesFactoryDefault() public {
        LPVault v = LPVault(_create());
        assertEq(v.emergencyCancelTimelock(), 7 days, "the vault should copy the 7-day default");
        assertEq(
            v.emergencyCancelTimelock(),
            factory.defaultEmergencyCancelTimelock(),
            "the vault's timelock should equal the factory default at creation"
        );
    }

    // SC-REQ6: clone's phase == Active (1)
    function test_clonePhaseIsActive() public {
        address vault = _create();
        assertEq(LPVault(vault).phase(), uint8(1), "phase should be Active (1)");
    }

    // SC-REQ6: clone's activeLiquidity == 0
    function test_cloneActiveLiquidityIsZero() public {
        address vault = _create();
        assertEq(LPVault(vault).activeLiquidity(), uint128(0), "activeLiquidity should start at 0");
    }

    // SC-REQ6: USDC.allowance(vault, exchange) == type(uint256).max
    function test_usdcApprovalIsMaxOnExchange() public {
        address vault = _create();
        assertEq(mockUsdc.allowance(vault, exchangeAddr), type(uint256).max, "USDC allowance should be max");
    }

    // SC-REQ6: ConditionalTokens.isApprovedForAll(vault, exchange) == true
    function test_conditionalTokensApprovalOnExchange() public {
        address vault = _create();
        assertTrue(ctf.isApprovedForAll(vault, exchangeAddr), "CT should be approvedForAll on exchange");
    }

    // SC-REQ6: VaultCreated event is emitted with correct args
    function test_emitsVaultCreatedEvent() public {
        // Pre-compute the expected clone address: first deployment from factory's nonce 1
        address expectedVault = computeCreateAddress(address(factory), 1);

        vm.expectEmit(true, false, false, true, address(factory));
        emit VaultCreated(marketId, expectedVault, minimumFirstLiquidity);

        _create();
    }
}

// ──────────────────────────────────────────────
// SC-REQ7: Duplicate marketId reverts
// What: A second createVault call with the same marketId reverts with
//       DuplicateMarket because vaultForMarket[marketId] is already non-zero.
// Why:  Each market must have exactly one vault. Allowing duplicates would
//       fragment liquidity and break the 1:1 marketId-to-vault invariant
//       that the keeper, UI, and indexer rely on.
// Example: oracle creates vault for marketId=0x01, then tries again →
//          revert DuplicateMarket.
// ──────────────────────────────────────────────
contract CreateVaultDuplicateMarketTest is LPVaultFixture {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
    }

    // SC-REQ7: second createVault with same marketId reverts DuplicateMarket
    function test_revertsOnDuplicateMarketId() public {
        (bytes32 conditionId, uint256 yesTokenId, uint256 noTokenId) = _prepareBinaryCondition(marketId, factory.usdc());
        vm.prank(oracleAddr);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, noTokenId);

        vm.prank(oracleAddr);
        vm.expectRevert(LPVaultFactory.DuplicateMarket.selector);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, noTokenId);
    }
}

// ──────────────────────────────────────────────
// SC-REQ8: Non-Oracle caller reverts
// What: Only the Oracle role can call createVault. Any other caller — Admin,
//       Operator, or arbitrary address — gets reverted with NotOracle.
// Why:  Oracle controls market lifecycle. Allowing operators or admins to
//       create vaults would violate role separation: Oracle decides which
//       markets exist, Operators execute trading actions.
// Example: operatorAddr calls createVault → revert NotOracle.
// ──────────────────────────────────────────────
contract CreateVaultAccessControlTest is LPVaultFixture {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address nobody = makeAddr("nobody");

    bytes32 conditionId;
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        (conditionId, yesTokenId, noTokenId) = _prepareBinaryCondition(bytes32(uint256(1)), address(mockUsdc));
    }

    // SC-REQ8: operator calling createVault reverts NotOracle
    function test_revertsWhenOperatorCallsCreateVault() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVaultFactory.NotOracle.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId);
    }

    // SC-REQ8: admin calling createVault reverts NotOracle
    function test_revertsWhenAdminCallsCreateVault() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.NotOracle.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId);
    }

    // SC-REQ8: arbitrary address calling createVault reverts NotOracle
    function test_revertsWhenNobodyCallsCreateVault() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotOracle.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId);
    }
}

// ──────────────────────────────────────────────
// SC-REQ9: Re-initialization of vault clone reverts
// What: Calling initialize() on an already-initialized vault clone reverts
//       with AlreadyInitialized. This holds regardless of who calls it.
// Why:  Double-init would overwrite per-vault config, reset approvals, and
//       break accounting for any positions already minted.
// Example: factory creates vault (clone initialized) → anyone calls
//          initialize() again → revert AlreadyInitialized.
// ──────────────────────────────────────────────
contract VaultReInitializeTest is LPVaultFixture {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
    }

    // SC-REQ9: calling initialize on an already-initialized clone reverts AlreadyInitialized
    function test_revertsOnDoubleInitialize() public {
        address vault = _createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000));

        // Any caller hitting initialize() on the already-initialized clone reverts
        vm.expectRevert(LPVault.AlreadyInitialized.selector);
        LPVault(vault)
            .initialize(
                bytes32(uint256(2)),
                makeAddr("usdc2"),
                makeAddr("exchange2"),
                makeAddr("ct2"),
                int24(20),
                address(this),
                uint128(2000),
                1,
                bytes32(uint256(2)),
                1,
                2
            );
    }
}

// ──────────────────────────────────────────────
// SC-REQA: Only factory can call initialize
// What: A freshly-deployed vault clone (not yet initialized) rejects
//       initialize() calls from any address that isn't the factory,
//       reverting with NotFactory. The factory_ parameter carries the
//       expected factory address; msg.sender must match.
// Why:  Defense-in-depth beyond initializer one-shot. Prevents a rogue
//       actor from racing to initialize a clone with arbitrary config
//       before the factory's atomic deploy-and-init completes.
// Example: deploy clone via assembly → non-factory calls
//          initialize(... factory_=realFactory ...) → revert NotFactory.
// ──────────────────────────────────────────────
contract VaultOnlyFactoryInitializeTest is LPVaultFixture {
    LPVault impl;
    LPVaultFactory factory;
    address nobody = makeAddr("nobody");

    function setUp() public {
        impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl),
            address(mockUsdc),
            makeAddr("exchange"),
            address(ctf),
            makeAddr("admin"),
            makeAddr("oracle"),
            makeAddr("operator")
        );
    }

    // SC-REQA: non-factory address calling initialize reverts NotFactory.
    // The clone is deployed by this test contract directly (not via the factory),
    // so msg.sender == address(this) != factory_ at the initialize call.
    function test_revertsWhenNonFactoryCallsInitialize() public {
        address clone = _createClone(address(impl));

        vm.prank(nobody);
        vm.expectRevert(LPVault.NotFactory.selector);
        LPVault(clone)
            .initialize(
                bytes32(uint256(1)),
                makeAddr("usdc"),
                makeAddr("exchange"),
                makeAddr("ct"),
                int24(10),
                address(factory), // declared factory address that msg.sender doesn't match
                uint128(1000),
                1,
                bytes32(uint256(1)),
                1,
                2
            );
    }

    function _createClone(address implementation) internal returns (address clone) {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            clone := create(0, ptr, 0x37)
        }
        require(clone != address(0), "clone deploy failed");
    }
}

// ──────────────────────────────────────────────
// SC-RG74: createVault reverts when minimumFirstLiquidity is zero
// What: Passing minimumFirstLiquidity == 0 to createVault reverts with
//       ZeroFloor — the invariant minimumFirstLiquidity > 0 is enforced
//       at vault creation time.
// Why:  A zero floor would allow the first mint to add zero liquidity,
//       creating a vault with no meaningful liquidity and breaking the
//       fee accumulator division when fees arrive with activeLiquidity == 0.
// Example: oracle calls createVault(marketId, tickSpacing, 0) → revert ZeroFloor.
// ──────────────────────────────────────────────
contract CreateVaultZeroFloorTest is LPVaultFixture {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
    }

    // SC-RG74: createVault with minimumFirstLiquidity == 0 reverts ZeroFloor
    function test_revertsOnZeroMinimumFirstLiquidity() public {
        (bytes32 conditionId, uint256 yesTokenId, uint256 noTokenId) =
            _prepareBinaryCondition(bytes32(uint256(1)), factory.usdc());
        vm.prank(oracleAddr);
        vm.expectRevert(LPVaultFactory.ZeroFloor.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(0), conditionId, yesTokenId, noTokenId);
    }
}

// ──────────────────────────────────────────────
// Shared setup for the outcome-token identity scenarios: a factory over the real
// ConditionalTokens contract, and helpers that prepare conditions and call createVault
// as the Oracle with an explicit identity.
// ──────────────────────────────────────────────
contract OutcomeIdentityTestBase is LPVaultFixture {
    LPVaultFactory factory;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));

    // A valid identity for marketId, prepared in setUp
    bytes32 conditionId;
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public virtual {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        (conditionId, yesTokenId, noTokenId) = _prepareBinaryCondition(marketId, address(mockUsdc));
    }

    /// @dev Calls createVault as the Oracle with the given identity.
    function _createAs(bytes32 conditionId_, uint256 yesTokenId_, uint256 noTokenId_) internal returns (address) {
        vm.prank(oracleAddr);
        return factory.createVault(marketId, int24(10), uint128(1000), conditionId_, yesTokenId_, noTokenId_);
    }

    /// @dev Asserts that no vault exists for marketId after a failed call.
    function _assertNoVault() internal view {
        assertEq(factory.vaultForMarket(marketId), address(0), "no vault should be registered for marketId");
    }
}

// ──────────────────────────────────────────────
// SC-6HBV: createVault reverts on a malformed outcome-token identity
// What: A zero conditionId, a zero token ID, or two equal token IDs each revert
//       with their own error before any clone exists and before the factory calls
//       the ConditionalTokens contract.
// Why:  A clone cannot correct its identity after initialize(), so a wrong identity
//       must never reach a clone. Each error names one defect so the Oracle service
//       can fix its input.
// Example: createVault(..., conditionId=0, yes, no) → revert ZeroConditionId.
// ──────────────────────────────────────────────
contract CreateVaultMalformedIdentityTest is OutcomeIdentityTestBase {
    // SC-6HBV: a zero condition ID reverts ZeroConditionId
    function test_revertsOnZeroConditionId() public {
        vm.expectRevert(LPVaultFactory.ZeroConditionId.selector);
        _createAs(bytes32(0), yesTokenId, noTokenId);
        _assertNoVault();
    }

    // SC-6HBV: a zero YES token ID reverts ZeroTokenId
    function test_revertsOnZeroYesTokenId() public {
        vm.expectRevert(LPVaultFactory.ZeroTokenId.selector);
        _createAs(conditionId, 0, noTokenId);
        _assertNoVault();
    }

    // SC-6HBV: a zero NO token ID reverts ZeroTokenId
    function test_revertsOnZeroNoTokenId() public {
        vm.expectRevert(LPVaultFactory.ZeroTokenId.selector);
        _createAs(conditionId, yesTokenId, 0);
        _assertNoVault();
    }

    // SC-6HBV: equal token IDs revert DuplicateTokenId
    function test_revertsOnDuplicateTokenId() public {
        vm.expectRevert(LPVaultFactory.DuplicateTokenId.selector);
        _createAs(conditionId, yesTokenId, yesTokenId);
        _assertNoVault();
    }

    // SC-6HBV: the value checks run before any call to the ConditionalTokens contract
    function test_malformedIdentityMakesNoConditionalTokensCall() public {
        vm.expectCall(address(ctf), abi.encodeWithSelector(ITestConditionalTokens.getOutcomeSlotCount.selector), 0);
        vm.expectRevert(LPVaultFactory.ZeroConditionId.selector);
        _createAs(bytes32(0), yesTokenId, noTokenId);
    }
}

// ──────────────────────────────────────────────
// SC-6HBW: createVault reverts when the condition is not a prepared binary condition
// What: An unprepared condition (outcome slot count 0) and a 3-outcome condition
//       both revert with NotBinaryCondition.
// Why:  The complete-set merge and the redemption use the partition [1, 2]. On a
//       3-outcome condition that partition mints a third token instead of paying
//       USDC. Prophet's Resolution.sol prepares only 2-outcome conditions.
// Example: createVault(..., unpreparedConditionId, yes, no) → revert NotBinaryCondition.
// ──────────────────────────────────────────────
contract CreateVaultNotBinaryConditionTest is OutcomeIdentityTestBase {
    // SC-6HBW: an unprepared condition returns outcome slot count 0 and reverts
    function test_revertsOnUnpreparedCondition() public {
        bytes32 unprepared = keccak256("never prepared");
        assertEq(ctf.getOutcomeSlotCount(unprepared), 0, "precondition: the condition is not prepared");

        vm.expectRevert(LPVaultFactory.NotBinaryCondition.selector);
        _createAs(unprepared, yesTokenId, noTokenId);
        _assertNoVault();
    }

    // SC-6HBW: a 3-outcome condition reverts although its two first position IDs are valid
    function test_revertsOnThreeOutcomeCondition() public {
        bytes32 questionId = keccak256("three outcomes");
        ctf.prepareCondition(address(this), questionId, 3);
        bytes32 ternary = ctf.getConditionId(address(this), questionId, 3);
        uint256 id1 = ctf.getPositionId(address(mockUsdc), ctf.getCollectionId(bytes32(0), ternary, 1));
        uint256 id2 = ctf.getPositionId(address(mockUsdc), ctf.getCollectionId(bytes32(0), ternary, 2));

        vm.expectRevert(LPVaultFactory.NotBinaryCondition.selector);
        _createAs(ternary, id1, id2);
        _assertNoVault();
    }
}

// ──────────────────────────────────────────────
// SC-6HBX: createVault reverts when the token IDs do not match the condition's index sets
// What: The valid pair of a different condition, and the correct pair in swapped
//       order, both revert with TokenIdMismatch.
// Why:  These are the two mistakes that look correct and that a clone can never undo:
//       a vault that names one market's condition and another market's tokens, or
//       a vault that labels NO as YES for its whole life.
// Example: createVault(..., conditionA, yesOfB, noOfB) → revert TokenIdMismatch.
// ──────────────────────────────────────────────
contract CreateVaultTokenIdMismatchTest is OutcomeIdentityTestBase {
    // SC-6HBX case A: another condition's valid pair reverts TokenIdMismatch
    function test_revertsOnAnotherConditionsPair() public {
        (, uint256 otherYes, uint256 otherNo) = _prepareBinaryCondition(keccak256("other market"), address(mockUsdc));

        vm.expectRevert(LPVaultFactory.TokenIdMismatch.selector);
        _createAs(conditionId, otherYes, otherNo);
        _assertNoVault();
    }

    // SC-6HBX case B: the correct pair in swapped order reverts TokenIdMismatch
    function test_revertsOnSwappedPair() public {
        vm.expectRevert(LPVaultFactory.TokenIdMismatch.selector);
        _createAs(conditionId, noTokenId, yesTokenId);
        _assertNoVault();
    }
}

// ──────────────────────────────────────────────
// NFR-RER0: createVault execution gas stays below 650,000 for any condition
// What: The identity check calls getCollectionId twice, and that call searches for
//       a curve point in a loop, so its cost differs per condition. The execution
//       gas of createVault must stay below 650,000 for every condition ID.
// Why:  A limit that no test checks is a comment. The E3 exploration measured the
//       cheapest condition at about 480,000 and the most expensive of 64 at about
//       547,000 with the optimizer off.
// Example: createVault over a random question ID uses fewer than 650,000 gas.
// ──────────────────────────────────────────────
contract CreateVaultGasLimitTest is OutcomeIdentityTestBase {
    uint256 constant CREATE_VAULT_GAS_LIMIT = 650_000;

    // NFR-RER0: execution gas of createVault is below the limit for a fuzzed condition
    function testFuzz_createVaultGasBelowLimit(bytes32 questionId) public {
        // setUp already prepared the condition for marketId, and the ConditionalTokens contract
        // rejects a second preparation of the same question
        vm.assume(questionId != marketId);
        (bytes32 fuzzedCondition, uint256 fuzzedYes, uint256 fuzzedNo) =
            _prepareBinaryCondition(questionId, address(mockUsdc));

        vm.prank(oracleAddr);
        uint256 before = gasleft();
        factory.createVault(questionId, int24(10), uint128(1000), fuzzedCondition, fuzzedYes, fuzzedNo);
        uint256 used = before - gasleft();

        assertLt(used, CREATE_VAULT_GAS_LIMIT, "createVault execution gas must stay below the NFR-RER0 limit");
    }
}

// ──────────────────────────────────────────────
// SC-RG75: Oracle updates minimumFirstLiquidity successfully
// What: The Oracle can change a vault's minimumFirstLiquidity to any
//       non-zero value via setMinimumFirstLiquidity. The old and new
//       values are logged in MinimumFirstLiquidityUpdated.
// Why:  Market conditions change — the Oracle may need to raise or lower
//       the first-mint floor post-creation without redeploying the vault.
// Example: vault.minimumFirstLiquidity == 1000, oracle calls
//          setMinimumFirstLiquidity(2000) → stored value = 2000,
//          MinimumFirstLiquidityUpdated(1000, 2000) emitted.
// ──────────────────────────────────────────────
contract SetMinFirstLiqSuccessTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));
    uint128 initialMin = uint128(1000);

    event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), initialMin));
    }

    // SC-RG75: oracle sets new minimumFirstLiquidity value
    function test_oracleUpdatesMinimumFirstLiquidity() public {
        uint128 newMin = uint128(2000);
        vm.prank(oracleAddr);
        vault.setMinimumFirstLiquidity(newMin);
        assertEq(vault.minimumFirstLiquidity(), newMin, "minimumFirstLiquidity should reflect new value");
    }

    // SC-RG75: MinimumFirstLiquidityUpdated event emitted with old and new values
    function test_emitsMinimumFirstLiquidityUpdatedEvent() public {
        uint128 newMin = uint128(2000);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MinimumFirstLiquidityUpdated(initialMin, newMin);

        vm.prank(oracleAddr);
        vault.setMinimumFirstLiquidity(newMin);
    }
}

// ──────────────────────────────────────────────
// SC-RG76: Non-Oracle caller cannot update minimumFirstLiquidity
// What: Only the Oracle can call setMinimumFirstLiquidity. Operators,
//       Admins, and arbitrary addresses all revert with NotOracle.
// Why:  minimumFirstLiquidity is a governance parameter that only the
//       Oracle (market lifecycle controller) should touch. Operators
//       handle transactional actions, not governance.
// Example: operatorAddr calls setMinimumFirstLiquidity(2000) → revert NotOracle.
// ──────────────────────────────────────────────
contract SetMinFirstLiqAccessControlTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address nobody = makeAddr("nobody");

    bytes32 marketId = bytes32(uint256(1));

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1000)));
    }

    // SC-RG76: operator calling setMinimumFirstLiquidity reverts NotOracle
    function test_revertsWhenOperatorCallsSetMinFirstLiq() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.setMinimumFirstLiquidity(uint128(2000));
    }

    // SC-RG76: admin calling setMinimumFirstLiquidity reverts NotOracle
    function test_revertsWhenAdminCallsSetMinFirstLiq() public {
        vm.prank(admin);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.setMinimumFirstLiquidity(uint128(2000));
    }

    // SC-RG76: arbitrary address calling setMinimumFirstLiquidity reverts NotOracle
    function test_revertsWhenNobodyCallsSetMinFirstLiq() public {
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.setMinimumFirstLiquidity(uint128(2000));
    }
}

// ──────────────────────────────────────────────
// SC-RG77: setMinimumFirstLiquidity reverts when newMin is zero
// What: Even when called by the Oracle, setMinimumFirstLiquidity(0)
//       reverts with ZeroFloor — the invariant minimumFirstLiquidity > 0
//       is enforced at the setter boundary, not just at creation time.
// Why:  A zero floor after creation would defeat the safety the creation
//       guard provides. The invariant must hold at every write path.
// Example: oracle calls setMinimumFirstLiquidity(0) → revert ZeroFloor.
// ──────────────────────────────────────────────
contract SetMinFirstLiqZeroTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1000)));
    }

    // SC-RG77: oracle calling setMinimumFirstLiquidity(0) reverts ZeroFloor
    function test_revertsOnZeroNewMin() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.ZeroFloor.selector);
        vault.setMinimumFirstLiquidity(uint128(0));
    }
}

// ──────────────────────────────────────────────
// SC-BZC2: Admin changes the default timelock, and only later vaults copy it
// What: An Admin sets the factory default to 14 days. A vault created before the
//       change keeps 7 days, a vault created after reads 14 days, and each vault's
//       freeze obeys its own copy.
// Why:  Decision C10 (ADR-BZC5): a default change must reach later vaults and never
//       an existing one, because the vault reads its own storage and not the factory.
// Example: V1 created at 7 days; Admin sets 14 days; V2 created -> V1 freezes after
//          7 days of silence, V2 reverts at 7 days and freezes at 14.
// ──────────────────────────────────────────────
contract DefaultTimelockChangeTest is LPVaultFixture {
    LPVaultFactory factory;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    uint256 constant LP_PK = 0xA11CE;
    address safe;

    event DefaultEmergencyCancelTimelockUpdated(uint32 oldTimelock, uint32 newTimelock);

    LPVault vault1;

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        safe = _safeOf(vm.addr(LP_PK));
        vault1 = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1)));
    }

    // SC-BZC2: the setter stores the new default and emits the old and new values
    function test_adminUpdatesDefaultAndEmits() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit DefaultEmergencyCancelTimelockUpdated(7 days, 14 days);

        vm.prank(admin);
        factory.setDefaultEmergencyCancelTimelock(14 days);

        assertEq(factory.defaultEmergencyCancelTimelock(), 14 days, "the default should be 14 days");
    }

    // SC-BZC2: a vault created before the change keeps its copy, a vault created after copies the new default
    function test_onlyLaterVaultsCopyTheNewDefault() public {
        vm.prank(admin);
        factory.setDefaultEmergencyCancelTimelock(14 days);

        LPVault vault2 = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(2)), int24(10), uint128(1)));

        assertEq(vault1.emergencyCancelTimelock(), 7 days, "the earlier vault keeps 7 days");
        assertEq(vault2.emergencyCancelTimelock(), 14 days, "the later vault copies 14 days");
    }

    // SC-BZC2: each vault's freeze obeys its own copy, not the factory's current default
    function test_eachVaultFreezesOnItsOwnTimelock() public {
        vm.prank(admin);
        factory.setDefaultEmergencyCancelTimelock(14 days);
        LPVault vault2 = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(2)), int24(10), uint128(1)));

        // Both vaults hold one position of the same Safe, so the same address can freeze either
        _escrowAndMint(vault1, operatorAddr, LP_PK, int24(0), int24(100), 1000, keccak256("v1"));
        _escrowAndMint(vault2, operatorAddr, LP_PK, int24(0), int24(100), 1000, keccak256("v2"));

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(safe);
        vault1.emergencyCancelAll();
        assertEq(vault1.phase(), 3, "the 7-day vault freezes after 7 days of silence");

        vm.prank(safe);
        vm.expectRevert(LPVault.TimelockNotElapsed.selector);
        vault2.emergencyCancelAll();

        vm.warp(block.timestamp + 7 days);

        vm.prank(safe);
        vault2.emergencyCancelAll();
        assertEq(vault2.phase(), 3, "the 14-day vault freezes after 14 days of silence");
    }
}

// ──────────────────────────────────────────────
// SC-BZC3: The default timelock setter rejects zero and a value above 30 days
// What: setDefaultEmergencyCancelTimelock(0) reverts ZeroTimelock, 30 days + 1 reverts
//       TimelockTooLong, and 30 days itself is accepted.
// Why:  FR-BZC1: a zero timelock lets any address freeze a vault one block after any
//       Operator call, and a value above 30 days holds LPs to a silent Operator too long.
// ──────────────────────────────────────────────
contract DefaultTimelockBoundsTest is LPVaultFixture {
    LPVaultFactory factory;

    address admin = makeAddr("admin");

    event DefaultEmergencyCancelTimelockUpdated(uint32 oldTimelock, uint32 newTimelock);

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl),
            address(mockUsdc),
            makeAddr("exchange"),
            address(ctf),
            admin,
            makeAddr("oracle"),
            makeAddr("operator")
        );
    }

    // SC-BZC3: zero reverts and the default is unchanged
    function test_revertsOnZeroTimelock() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.ZeroTimelock.selector);
        factory.setDefaultEmergencyCancelTimelock(0);

        assertEq(factory.defaultEmergencyCancelTimelock(), 7 days, "the default stays 7 days");
    }

    // SC-BZC3: one second above the cap reverts and the default is unchanged
    function test_revertsAboveThirtyDays() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.TimelockTooLong.selector);
        factory.setDefaultEmergencyCancelTimelock(30 days + 1);

        assertEq(factory.defaultEmergencyCancelTimelock(), 7 days, "the default stays 7 days");
    }

    // SC-BZC3: the cap itself is accepted
    function test_acceptsExactlyThirtyDays() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit DefaultEmergencyCancelTimelockUpdated(7 days, 30 days);

        vm.prank(admin);
        factory.setDefaultEmergencyCancelTimelock(30 days);

        assertEq(factory.defaultEmergencyCancelTimelock(), 30 days, "the default should be 30 days");
    }
}

// ──────────────────────────────────────────────
// SC-BZC4: Non-Admin cannot change the default timelock
// What: The Operator, the Oracle, an LP's Safe, and an arbitrary address each revert
//       NotAdmin, and the default stays 7 days.
// Why:  FR-REQZ: a protocol-wide default is factory configuration, the Admin's registry
//       role. The Oracle case matters most: the Oracle owns the market lifecycle, not
//       factory defaults.
// ──────────────────────────────────────────────
contract DefaultTimelockAccessControlTest is LPVaultFixture {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
    }

    function _assertRejected(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.setDefaultEmergencyCancelTimelock(14 days);
        assertEq(factory.defaultEmergencyCancelTimelock(), 7 days, "the default stays 7 days");
    }

    // SC-BZC4: the Operator is rejected
    function test_revertsWhenOperatorSetsDefault() public {
        _assertRejected(operatorAddr);
    }

    // SC-BZC4: the Oracle is rejected
    function test_revertsWhenOracleSetsDefault() public {
        _assertRejected(oracleAddr);
    }

    // SC-BZC4: an LP's Safe and an arbitrary address are rejected
    function test_revertsWhenSafeOrNobodySetsDefault() public {
        _assertRejected(_safeOf(vm.addr(0xA11CE)));
        _assertRejected(makeAddr("nobody"));
    }
}

// ──────────────────────────────────────────────
// SC-3WLL, SC-3WLM: Vault accepts inbound ERC-1155 outcome tokens
// What: A safeTransferFrom / safeBatchTransferFrom of outcome tokens from the
//       vault's own ConditionalTokens contract lands in the vault, because the
//       vault answers the receiver hooks with the ERC-1155 acknowledgement values.
// Why:  The vault exists to hold outcome tokens acquired through trading. Without
//       the hooks every such transfer reverts, which is a permanent denial of the
//       vault's core function rather than an edge case.
// Example: holder transfers 500e6 of the YES token id to the vault → the transfer
//          completes, the vault's balance is 500e6, and the hook returned 0xf23a6e61.
// ──────────────────────────────────────────────
contract VaultReceivesOutcomeTokensTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address holder = makeAddr("holder");

    bytes32 marketId = bytes32(uint256(1));

    // The vault's two outcome token IDs, read back from the vault after creation
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1000)));
        yesTokenId = vault.yesTokenId();
        noTokenId = vault.noTokenId();

        // The holder splits 1,000 USDC into 1,000 YES and 1,000 NO through the real contract
        _mintCompleteSets(mockUsdc, holder, vault.conditionId(), 1_000e6);
    }

    // SC-3WLL: a single safeTransferFrom from ConditionalTokens completes and credits the vault
    function test_acceptsSingleOutcomeTokenTransfer() public {
        vm.prank(holder);
        ctf.safeTransferFrom(holder, address(vault), yesTokenId, 500e6, "");

        assertEq(ctf.balanceOf(address(vault), yesTokenId), 500e6, "vault should hold the transferred YES tokens");
        assertEq(ctf.balanceOf(holder, yesTokenId), 500e6, "holder balance should be debited");
    }

    // SC-3WLL: the hook returns the ERC-1155 single-transfer acknowledgement value
    function test_onERC1155ReceivedReturnsMagicValue() public {
        vm.prank(address(ctf));
        bytes4 ack = IERC1155Receiver(address(vault)).onERC1155Received(holder, holder, yesTokenId, 500e6, "");

        assertEq(ack, bytes4(0xf23a6e61), "onERC1155Received must return 0xf23a6e61");
    }

    // SC-3WLM: a batch safeBatchTransferFrom of both outcomes completes and credits the vault
    function test_acceptsBatchOutcomeTokenTransfer() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId;
        ids[1] = noTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300e6;
        amounts[1] = 200e6;

        vm.prank(holder);
        ctf.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");

        assertEq(ctf.balanceOf(address(vault), yesTokenId), 300e6, "vault should hold the transferred YES tokens");
        assertEq(ctf.balanceOf(address(vault), noTokenId), 200e6, "vault should hold the transferred NO tokens");
    }

    // SC-3WLM: the batch hook returns the ERC-1155 batch-transfer acknowledgement value
    function test_onERC1155BatchReceivedReturnsMagicValue() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId;
        ids[1] = noTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300e6;
        amounts[1] = 200e6;

        vm.prank(address(ctf));
        bytes4 ack = IERC1155Receiver(address(vault)).onERC1155BatchReceived(holder, holder, ids, amounts, "");

        assertEq(ack, bytes4(0xbc197c81), "onERC1155BatchReceived must return 0xbc197c81");
    }

    // SC-3WLL, SC-3WLM: receiving tokens is invisible to position/tick/fee accounting.
    // Vault bookkeeping is driven by mint, burn, collect, and notifyFees — never by
    // observing an inbound transfer — so an arriving token must move no accounting state.
    function test_receivingTokensLeavesVaultAccountingUntouched() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId;
        ids[1] = noTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300e6;
        amounts[1] = 200e6;

        vm.startPrank(holder);
        ctf.safeTransferFrom(holder, address(vault), yesTokenId, 100e6, "");
        ctf.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");
        vm.stopPrank();

        assertEq(vault.activeLiquidity(), 0, "activeLiquidity must not move on an inbound transfer");
        assertEq(vault.currentTick(), int24(0), "currentTick must not move on an inbound transfer");
        assertEq(vault.feeGrowthGlobalX128(), 0, "feeGrowthGlobalX128 must not move on an inbound transfer");
        assertEq(vault.nextPositionId(), 0, "nextPositionId must not move on an inbound transfer");
    }
}

// ──────────────────────────────────────────────
// SC-3WLN: Receiver hook called by a non-ConditionalTokens address reverts
// What: Both receiver hooks revert unless msg.sender is the vault's configured
//       conditionalTokens address.
// Why:  Inside a receiver hook msg.sender is the token contract. Guarding on it
//       turns the assumption documented at the setApprovalForAll call site — that
//       the vault only ever holds outcome tokens for its one market — into an
//       enforced on-chain check instead of a comment.
// Example: an arbitrary EOA, or an unrelated ERC-1155 contract trying to push its
//          own token ids into the vault, both revert with NotConditionalTokens.
// ──────────────────────────────────────────────
contract VaultRejectsForeignERC1155Test is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    ForeignERC1155 foreignToken;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address stranger = makeAddr("stranger");

    bytes32 marketId = bytes32(uint256(1));
    uint256 foreignTokenId = uint256(keccak256("SOME OTHER MARKET"));

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        foreignToken = new ForeignERC1155();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1000)));
    }

    // SC-3WLN: an arbitrary EOA calling the single-transfer hook directly reverts
    function test_revertsWhenSingleHookCalledByEOA() public {
        vm.prank(stranger);
        vm.expectRevert(LPVault.NotConditionalTokens.selector);
        IERC1155Receiver(address(vault)).onERC1155Received(stranger, stranger, foreignTokenId, 1e6, "");
    }

    // SC-3WLN: an arbitrary EOA calling the batch hook directly reverts
    function test_revertsWhenBatchHookCalledByEOA() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = foreignTokenId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;

        vm.prank(stranger);
        vm.expectRevert(LPVault.NotConditionalTokens.selector);
        IERC1155Receiver(address(vault)).onERC1155BatchReceived(stranger, stranger, ids, amounts, "");
    }

    // SC-3WLN: an unrelated ERC-1155 contract cannot push its token ids into the vault
    function test_revertsWhenForeignTokenContractTransfersToVault() public {
        vm.prank(stranger);
        vm.expectRevert(LPVault.NotConditionalTokens.selector);
        foreignToken.safeTransferFrom(stranger, address(vault), foreignTokenId, 1e6, "");
    }

    // SC-3WLN: the operator holds no special power here either — the guard is on the
    // token contract identity, not on a role
    function test_revertsWhenOperatorCallsHook() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVault.NotConditionalTokens.selector);
        IERC1155Receiver(address(vault)).onERC1155Received(operatorAddr, operatorAddr, foreignTokenId, 1e6, "");
    }
}

// ──────────────────────────────────────────────
// SC-6HBY: Receiver hook rejects a token ID outside the vault's market
// What: A transfer from the vault's own ConditionalTokens contract of a token that
//       belongs to a second condition reverts with UnknownTokenId, on a single transfer
//       and on a batch that also carries a valid ID.
// Why:  With the caller check (SC-3WLN), this turns the one-market assumption behind
//       the unscoped setApprovalForAll into an on-chain check on both the token
//       contract and the token ID.
// Example: holder transfers a YES token of condition B to a vault for condition A →
//          revert UnknownTokenId, and the vault's balances do not change.
// ──────────────────────────────────────────────
contract VaultRejectsForeignTokenIdTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address holder = makeAddr("holder");

    bytes32 marketId = bytes32(uint256(1));

    uint256 yesTokenId;
    uint256 foreignTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, marketId, int24(10), uint128(1000)));
        yesTokenId = vault.yesTokenId();

        // The holder owns tokens of the vault's condition and of a second condition on the same contract
        _mintCompleteSets(mockUsdc, holder, vault.conditionId(), 1_000e6);
        (bytes32 foreignCondition, uint256 foreignYes,) =
            _prepareBinaryCondition(keccak256("other market"), address(mockUsdc));
        _mintCompleteSets(mockUsdc, holder, foreignCondition, 1_000e6);
        foreignTokenId = foreignYes;
    }

    // SC-6HBY: a single transfer of a foreign token ID reverts UnknownTokenId
    function test_revertsOnSingleTransferOfForeignTokenId() public {
        vm.prank(holder);
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        ctf.safeTransferFrom(holder, address(vault), foreignTokenId, 100e6, "");

        assertEq(ctf.balanceOf(address(vault), foreignTokenId), 0, "the foreign token must not reach the vault");
    }

    // SC-6HBY: a batch that carries one valid and one foreign ID reverts UnknownTokenId
    function test_revertsOnBatchWithForeignTokenId() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId;
        ids[1] = foreignTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 100e6;

        vm.prank(holder);
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        ctf.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");

        assertEq(ctf.balanceOf(address(vault), yesTokenId), 0, "the valid ID in a rejected batch must not land either");
        assertEq(ctf.balanceOf(address(vault), foreignTokenId), 0, "the foreign token must not reach the vault");
    }

    // SC-6HBY: the hook itself, called by the ConditionalTokens contract with a foreign ID, reverts
    function test_hookRevertsOnForeignTokenIdFromConditionalTokens() public {
        vm.prank(address(ctf));
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        IERC1155Receiver(address(vault)).onERC1155Received(holder, holder, foreignTokenId, 100e6, "");
    }
}

// ──────────────────────────────────────────────
// SC-3WLO: Vault reports ERC-1155 receiver interface support
// What: supportsInterface returns true for IERC1155Receiver, for ERC-165 itself, and for
//       EIP-1271 (the order maker, FR-3WLK), and false for anything else.
// Why:  Some callers ERC-165-probe a recipient before transferring. Without a truthful
//       answer they skip the transfer entirely, even though the hooks work.
// Example: supportsInterface(0x4e2312e0) == true, supportsInterface(0xffffffff) == false.
// ──────────────────────────────────────────────
contract VaultSupportsInterfaceTest is LPVaultFixture {
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        LPVaultFactory factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000)));
    }

    // SC-3WLO: the IERC1155Receiver interface id is reported as supported
    function test_reportsIERC1155ReceiverSupport() public view {
        assertTrue(
            IERC1155Receiver(address(vault)).supportsInterface(bytes4(0x4e2312e0)),
            "vault must report IERC1155Receiver support"
        );
    }

    // SC-3WLO: the ERC-165 interface id itself is reported as supported
    function test_reportsERC165Support() public view {
        assertTrue(
            IERC1155Receiver(address(vault)).supportsInterface(bytes4(0x01ffc9a7)), "vault must report ERC-165 support"
        );
    }

    // SC-3WLO, FR-3WLK: the EIP-1271 interface id is reported as supported (FEAT-C0DJ)
    function test_reportsEIP1271Support() public view {
        assertTrue(
            IERC1155Receiver(address(vault)).supportsInterface(bytes4(0x1626ba7e)), "vault must report EIP-1271 support"
        );
    }

    // SC-3WLO: an unsupported interface id is reported as unsupported
    function test_reportsUnsupportedInterfaceAsFalse() public view {
        assertFalse(
            IERC1155Receiver(address(vault)).supportsInterface(bytes4(0xffffffff)),
            "vault must not claim support for an arbitrary interface id"
        );
    }
}

// ──────────────────────────────────────────────
// FR-FKD0: Vault operator auth delegates to factory
// What: The vault's operators(addr) function reads from the factory's
//       operator registry via cross-contract call, not from local storage.
// Why:  Centralizing the operator registry on the factory means a single
//       addOperator/removeOperator call propagates to every deployed vault
//       instantly — no per-vault updates needed for key rotation.
// Example: factory.operators(operatorAddr) == 1, vault.operators(operatorAddr) == 1.
// ──────────────────────────────────────────────
contract VaultOperatorDelegationTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000)));
    }

    // FR-FKD0: vault.operators(addr) returns factory.operators(addr)
    function test_vaultOperatorsReadsFromFactory() public view {
        assertEq(vault.operators(operatorAddr), factory.operators(operatorAddr));
        assertEq(vault.operators(operatorAddr), uint256(1));
    }

    // FR-FKD0: non-operator returns 0 via delegation
    function test_vaultOperatorsReturnsZeroForNonOperator() public {
        address nobody = makeAddr("nobody");
        assertEq(vault.operators(nobody), uint256(0));
        assertEq(vault.operators(nobody), factory.operators(nobody));
    }
}

// ──────────────────────────────────────────────
// FR-FKD1: Vault oracle auth delegates to factory
// What: The vault's oracle() function reads from the factory's oracle
//       address via cross-contract call, not from local storage.
// Why:  Oracle rotation on the factory takes immediate effect on all
//       vaults — the vault never stores a stale oracle address.
// Example: factory.oracle() == oracleAddr, vault.oracle() == oracleAddr.
// ──────────────────────────────────────────────
contract VaultOracleDelegationTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000)));
    }

    // FR-FKD1: vault.oracle() returns factory.oracle()
    function test_vaultOracleReadsFromFactory() public view {
        assertEq(vault.oracle(), factory.oracle());
        assertEq(vault.oracle(), oracleAddr);
    }
}

// ──────────────────────────────────────────────
// FR-FKD2: Vault admin auth delegates to factory
// What: The vault's admins(addr) function reads from the factory's admin
//       registry via cross-contract call, not from local storage.
// Why:  Admin transfers on the factory propagate to all vaults without
//       needing per-vault admin management functions.
// Example: factory.admins(admin) == 1, vault.admins(admin) == 1.
// ──────────────────────────────────────────────
contract VaultAdminDelegationTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000)));
    }

    // FR-FKD2: vault.admins(addr) returns factory.admins(addr)
    function test_vaultAdminsReadsFromFactory() public view {
        assertEq(vault.admins(admin), factory.admins(admin));
        assertEq(vault.admins(admin), uint256(1));
    }

    // FR-FKD2: non-admin returns 0 via delegation
    function test_vaultAdminsReturnsZeroForNonAdmin() public {
        address nobody = makeAddr("nobody");
        assertEq(vault.admins(nobody), uint256(0));
        assertEq(vault.admins(nobody), factory.admins(nobody));
    }
}

// ──────────────────────────────────────────────
// FR-FKD3: Vault has no local role state
// What: The vault does not write operators, oracle, admins, pendingAdmin,
//       or adminCount to its own storage during initialize() — all role
//       state is read from the factory at call time.
// Why:  Local role copies create stale-registry risk. With no local state,
//       there is nothing to go stale.
// Example: vault created → vault.admins(admin) == 1 via factory delegation,
//          but no admins mapping exists locally on the vault.
// ──────────────────────────────────────────────
contract VaultNoLocalRoleStateTest is LPVaultFixture {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        _deployConditionalTokens();
        factory = _deployFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(ctf), admin, oracleAddr, operatorAddr
        );
        vault = LPVault(_createVault(factory, oracleAddr, bytes32(uint256(1)), int24(10), uint128(1000)));
    }

    // FR-FKD3: vault delegation reflects live factory state.
    // If the factory adds a new operator, the vault sees it immediately
    // because it reads from factory, not from a local copy.
    function test_vaultReflectsLiveFactoryState() public {
        address newOp = makeAddr("newOperator");

        // Before: vault doesn't recognize newOp as operator
        assertEq(vault.operators(newOp), uint256(0));

        // Factory adds newOp
        vm.prank(admin);
        factory.addOperator(newOp);

        // After: vault immediately recognizes newOp (no vault-side update needed)
        assertEq(vault.operators(newOp), uint256(1));
    }
}
