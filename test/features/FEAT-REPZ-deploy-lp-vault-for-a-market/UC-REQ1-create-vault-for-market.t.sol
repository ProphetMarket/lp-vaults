// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ1: Create Vault for Market
// Integration tests for every scenario in this use case.
// Covers: SC-REQ6, SC-REQ7, SC-REQ8, SC-REQ9, SC-REQA, SC-RG74, SC-5XY4, SC-5XY5,
//         SC-RG75, SC-RG76, SC-RG77, SC-3WLL, SC-3WLM, SC-3WLN, SC-5XY6, SC-3WLO

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";
import {CTFPositionIds} from "../../mocks/CTFPositionIds.sol";

// ──────────────────────────────────────────────
// Minimal mocks — test-only contracts that stub the ERC-20 and ERC-1155
// interfaces the vault's initialize() calls (approve, setApprovalForAll).
// ──────────────────────────────────────────────

contract MockERC20 {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

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

/// @dev Minimal but *real* ERC-1155. It tracks balances and, on a safe transfer to a
///      contract, invokes the receiver hook and reverts unless the acknowledgement
///      value comes back — the behavior that makes an unimplemented hook a hard DOS.
///      A stub that skipped the callback would let these tests pass against a vault
///      that cannot actually receive tokens.
contract MockConditionalTokens is CTFPositionIds {
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => mapping(address => uint256)) public balanceOf;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[id][to] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        balanceOf[id][from] -= amount;
        balanceOf[id][to] += amount;
        if (to.code.length > 0) {
            bytes4 ack = IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data);
            require(ack == 0xf23a6e61, "ERC1155: receiver rejected");
        }
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        for (uint256 i = 0; i < ids.length; i++) {
            balanceOf[ids[i]][from] -= amounts[i];
            balanceOf[ids[i]][to] += amounts[i];
        }
        if (to.code.length > 0) {
            bytes4 ack = IERC1155Receiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data);
            require(ack == 0xbc197c81, "ERC1155: receiver rejected");
        }
    }
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
// Example: oracle calls createVault(marketId=0x01, tickSpacing=10, minLiq=1000)
//          → clone deployed at nonzero address, all storage set, USDC allowance
//          = max, CT approvedForAll = true, VaultCreated event emitted.
// ──────────────────────────────────────────────
contract CreateVaultSuccessTest is Test {
    LPVaultFactory factory;
    LPVault impl;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address exchangeAddr = makeAddr("exchange");

    bytes32 marketId = bytes32(uint256(1));
    int24 tickSpacing = int24(10);
    uint128 minimumFirstLiquidity = uint128(1000);

    // The market's outcome-token identity: one prepared condition and the two ERC-1155
    // position ids that derive from it under USDC collateral.
    bytes32 conditionId = keccak256("PROPHET-MARKET-1-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    // Event re-declared so we can use vm.expectEmit on it
    event VaultCreated(bytes32 indexed marketId, address vault, uint128 minimumFirstLiquidity);

    function setUp() public {
        impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
    }

    // SC-REQ6: vaultForMarket returns non-zero clone address
    function test_vaultForMarketReturnsCloneAddress() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        assertTrue(vault != address(0), "vault address should be non-zero");
        assertEq(factory.vaultForMarket(marketId), vault, "registry should map marketId to vault");
    }

    // SC-REQ6: clone's marketId matches
    function test_cloneMarketIdMatches() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        assertEq(LPVault(vault).marketId(), marketId, "clone marketId should match");
    }

    // SC-REQ6: the clone can name the two outcome tokens it is allowed to hold and the
    // conditionId a complete-set split requires — all three readable straight off the vault.
    function test_cloneStoresOutcomeTokenIdentity() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        LPVault v = LPVault(vault);
        assertEq(v.conditionId(), conditionId, "clone conditionId should match the value passed to createVault");
        assertEq(v.yesTokenId(), yesTokenId, "clone yesTokenId should match the value passed to createVault");
        assertEq(v.noTokenId(), noTokenId, "clone noTokenId should match the value passed to createVault");
    }

    // SC-REQ6: the derivation check verifies the pair as a set, so the Oracle's argument
    // order is what names which id is YES. Passing them swapped is equally valid and the
    // vault records whichever came first as its yesTokenId.
    function test_tokenIdsMayBePassedInEitherOrder() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, noTokenId, yesTokenId);
        LPVault v = LPVault(vault);
        assertEq(v.yesTokenId(), noTokenId, "the first id passed is stored as yesTokenId");
        assertEq(v.noTokenId(), yesTokenId, "the second id passed is stored as noTokenId");
    }

    // NFR-RER0 (partial): a regression tripwire on the vault-side cost of createVault,
    // NOT a verification of the 500,000 gas ceiling on Polygon.
    //
    // This measurement understates the real cost. The identity check calls getCollectionId
    // twice, and the real Gnosis ConditionalTokens derives an alt_bn128 point per call —
    // a modexp precompile inside a retry loop. CTFPositionIds answers with a single
    // keccak256, so the exact cost this test exists to account for is the cost the mock
    // elides, and the headroom left under the ceiling is the same order of magnitude as
    // the elided amount. Only a forked-Polygon run against the deployed ConditionalTokens
    // can settle whether NFR-RER0 still holds; see the plan's deferred fork-test note.
    //
    // The assertion is still worth keeping: it fails loudly if the vault-side cost grows.
    function test_createVaultVaultSideGasStaysUnderCeiling() public {
        vm.prank(oracleAddr);
        uint256 gasBefore = gasleft();
        factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 500_000, "vault-side createVault cost regressed past the NFR-RER0 ceiling");
    }

    // SC-REQ6: clone's usdc, exchange, conditionalTokens, oracle, tickSpacing, factory match factory values
    function test_cloneConfigMatchesFactoryValues() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        LPVault v = LPVault(vault);
        assertEq(v.usdc(), address(mockUsdc), "usdc should match factory");
        assertEq(v.exchange(), exchangeAddr, "exchange should match factory");
        assertEq(v.conditionalTokens(), address(mockCt), "conditionalTokens should match factory");
        assertEq(v.oracle(), oracleAddr, "oracle should match factory");
        assertEq(v.tickSpacing(), tickSpacing, "tickSpacing should match passed value");
        assertEq(v.factory(), address(factory), "factory should be the deploying factory");
    }

    // SC-REQ6: clone's minimumFirstLiquidity matches the passed value
    function test_cloneMinimumFirstLiquidityMatches() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        assertEq(LPVault(vault).minimumFirstLiquidity(), minimumFirstLiquidity, "minimumFirstLiquidity should match");
    }

    // SC-REQ6: clone's phase == Active (1)
    function test_clonePhaseIsActive() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        assertEq(LPVault(vault).phase(), uint8(1), "phase should be Active (1)");
    }

    // SC-REQ6: clone's activeLiquidity == 0
    function test_cloneActiveLiquidityIsZero() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        assertEq(LPVault(vault).activeLiquidity(), uint128(0), "activeLiquidity should start at 0");
    }

    // SC-REQ6: USDC.allowance(vault, exchange) == type(uint256).max
    function test_usdcApprovalIsMaxOnExchange() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        assertEq(mockUsdc.allowance(vault, exchangeAddr), type(uint256).max, "USDC allowance should be max");
    }

    // SC-REQ6: ConditionalTokens.isApprovedForAll(vault, exchange) == true
    function test_conditionalTokensApprovalOnExchange() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
        assertTrue(mockCt.isApprovedForAll(vault, exchangeAddr), "CT should be approvedForAll on exchange");
    }

    // SC-REQ6: VaultCreated event is emitted with correct args
    function test_emitsVaultCreatedEvent() public {
        // Pre-compute the expected clone address: first deployment from factory's nonce 1
        address expectedVault = computeCreateAddress(address(factory), 1);

        vm.expectEmit(true, false, false, true, address(factory));
        emit VaultCreated(marketId, expectedVault, minimumFirstLiquidity);

        vm.prank(oracleAddr);
        factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
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
contract CreateVaultDuplicateMarketTest is Test {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
    }

    // SC-REQ7: second createVault with same marketId reverts DuplicateMarket
    function test_revertsOnDuplicateMarketId() public {
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
contract CreateVaultAccessControlTest is Test {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address nobody = makeAddr("nobody");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
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
contract VaultReInitializeTest is Test {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
    }

    // SC-REQ9: calling initialize on an already-initialized clone reverts AlreadyInitialized
    function test_revertsOnDoubleInitialize() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId);

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
                conditionId,
                yesTokenId,
                noTokenId
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
contract VaultOnlyFactoryInitializeTest is Test {
    LPVault impl;
    LPVaultFactory factory;
    address nobody = makeAddr("nobody");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl),
            address(mockUsdc),
            makeAddr("exchange"),
            address(mockCt),
            makeAddr("admin"),
            makeAddr("oracle"),
            makeAddr("operator")
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
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
                conditionId,
                yesTokenId,
                noTokenId
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
contract CreateVaultZeroFloorTest is Test {
    LPVaultFactory factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
    }

    // SC-RG74: createVault with minimumFirstLiquidity == 0 reverts ZeroFloor
    function test_revertsOnZeroMinimumFirstLiquidity() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVaultFactory.ZeroFloor.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(0), conditionId, yesTokenId, noTokenId);
    }
}

// ──────────────────────────────────────────────
// SC-5XY4: createVault reverts on a malformed outcome-token identity
// What: A zero conditionId, a zero yesTokenId or noTokenId, or the same id passed
//       twice all revert at initialize() — and leave no vault registered.
// Why:  A clone's identity cannot be corrected after initialize(); clones are not
//       upgradable and there is no setter. A vault that names the wrong tokens, or
//       no tokens, would pay out and split the wrong assets for the rest of its life.
//       The only safe treatment is to make the state unreachable.
// Example: oracle calls createVault(..., conditionId=0, yes, no) → revert
//          ZeroConditionId, and vaultForMarket[marketId] is still address(0).
// ──────────────────────────────────────────────
contract CreateVaultMalformedIdentityTest is Test {
    LPVaultFactory factory;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
    }

    // SC-5XY4: a zero conditionId reverts — splitPosition would have nothing to split against
    function test_revertsOnZeroConditionId() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.ZeroConditionId.selector);
        factory.createVault(marketId, int24(10), uint128(1000), bytes32(0), yesTokenId, noTokenId);
    }

    // SC-5XY4: a zero yesTokenId reverts
    function test_revertsOnZeroYesTokenId() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.ZeroTokenId.selector);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, 0, noTokenId);
    }

    // SC-5XY4: a zero noTokenId reverts
    function test_revertsOnZeroNoTokenId() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.ZeroTokenId.selector);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, 0);
    }

    // SC-5XY4: the same id passed for both outcomes reverts — a market has two distinct
    // outcome tokens, and a vault that thinks YES and NO are the same token cannot
    // represent a two-sided position at all
    function test_revertsOnDuplicateTokenIds() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.DuplicateTokenId.selector);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, yesTokenId);
    }

    // SC-5XY4: after a rejected creation the market is still free, so the Oracle can
    // retry with the correct identity rather than losing the market to a half-made vault
    function test_registryStaysEmptyAfterRejectedCreation() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.ZeroConditionId.selector);
        factory.createVault(marketId, int24(10), uint128(1000), bytes32(0), yesTokenId, noTokenId);

        assertEq(factory.vaultForMarket(marketId), address(0), "no vault should be registered after a revert");

        vm.prank(oracleAddr);
        address vault = factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, noTokenId);
        assertEq(factory.vaultForMarket(marketId), vault, "the retry with a valid identity should succeed");
    }
}

// ──────────────────────────────────────────────
// SC-5XY5: createVault reverts when the token ids do not derive from the conditionId
// What: The vault derives the expected position-id pair from its collateral and the
//       supplied conditionId, and rejects any pair that isn't exactly that set — even
//       when both ids are nonzero, distinct, and are real position ids of some other
//       market's condition.
// Why:  This is the one misconfiguration the cheap checks cannot catch and the one that
//       cannot be undone: a correct-looking pair from the wrong condition. The vault
//       would hold, split, and pay out tokens belonging to a different market.
// Example: oracle passes market B's id pair with market A's conditionId → revert
//          TokenIdMismatch, no vault registered.
// ──────────────────────────────────────────────
contract CreateVaultIdentityMismatchTest is Test {
    LPVaultFactory factory;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));
    bytes32 conditionId = keccak256("PROPHET-MARKET-A-CONDITION");
    bytes32 otherConditionId = keccak256("PROPHET-MARKET-B-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;
    uint256 otherYesTokenId;
    uint256 otherNoTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        (otherYesTokenId, otherNoTokenId) = mockCt.idsFor(address(mockUsdc), otherConditionId);
    }

    // SC-5XY5: both ids belong to another market's condition — the exact misconfiguration
    // the zero and distinctness checks cannot see
    function test_revertsWhenBothIdsBelongToAnotherCondition() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.TokenIdMismatch.selector);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, otherYesTokenId, otherNoTokenId);
    }

    // SC-5XY5: one correct id and one foreign id is still a rejection — half-right is wrong
    function test_revertsWhenOnlyOneIdIsCorrect() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.TokenIdMismatch.selector);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, otherNoTokenId);
    }

    // SC-5XY5: an arbitrary nonzero value that is no position id at all is rejected
    function test_revertsOnArbitraryNonZeroIds() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.TokenIdMismatch.selector);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, 12345, 67890);
    }

    // SC-5XY5: a rejected mismatch leaves the market unregistered
    function test_registryStaysEmptyAfterMismatch() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.TokenIdMismatch.selector);
        factory.createVault(marketId, int24(10), uint128(1000), conditionId, otherYesTokenId, otherNoTokenId);

        assertEq(factory.vaultForMarket(marketId), address(0), "no vault should be registered after a mismatch");
    }

    // SC-5XY5: the matching pair for the *other* condition creates that market's vault
    // fine — the check is per-condition, not a blanket rejection of unfamiliar ids
    function test_correctPairForOtherConditionSucceeds() public {
        vm.prank(oracleAddr);
        address vault =
            factory.createVault(marketId, int24(10), uint128(1000), otherConditionId, otherYesTokenId, otherNoTokenId);

        assertEq(LPVault(vault).conditionId(), otherConditionId, "vault should carry the condition it was created for");
        assertEq(LPVault(vault).yesTokenId(), otherYesTokenId, "vault should carry that condition's YES id");
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
contract SetMinFirstLiqSuccessTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));
    uint128 initialMin = uint128(1000);

    event MinimumFirstLiquidityUpdated(uint128 oldMin, uint128 newMin);

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), initialMin, conditionId, yesTokenId, noTokenId));
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
contract SetMinFirstLiqAccessControlTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address nobody = makeAddr("nobody");

    bytes32 marketId = bytes32(uint256(1));

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, noTokenId));
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
contract SetMinFirstLiqZeroTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    bytes32 marketId = bytes32(uint256(1));

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, noTokenId));
    }

    // SC-RG77: oracle calling setMinimumFirstLiquidity(0) reverts ZeroFloor
    function test_revertsOnZeroNewMin() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.ZeroFloor.selector);
        vault.setMinimumFirstLiquidity(uint128(0));
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
contract VaultReceivesOutcomeTokensTest is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address holder = makeAddr("holder");

    bytes32 marketId = bytes32(uint256(1));

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, noTokenId));

        mockCt.mint(holder, yesTokenId, 1_000e6);
        mockCt.mint(holder, noTokenId, 1_000e6);
    }

    // SC-3WLL: a single safeTransferFrom from ConditionalTokens completes and credits the vault
    function test_acceptsSingleOutcomeTokenTransfer() public {
        vm.prank(holder);
        mockCt.safeTransferFrom(holder, address(vault), yesTokenId, 500e6, "");

        assertEq(mockCt.balanceOf(yesTokenId, address(vault)), 500e6, "vault should hold the transferred YES tokens");
        assertEq(mockCt.balanceOf(yesTokenId, holder), 500e6, "holder balance should be debited");
    }

    // SC-3WLL: the same holds for the NO outcome — both of the vault's own ids are
    // accepted on the single-transfer path, not just the one it labels YES
    function test_acceptsSingleNoOutcomeTokenTransfer() public {
        vm.prank(holder);
        mockCt.safeTransferFrom(holder, address(vault), noTokenId, 400e6, "");

        assertEq(mockCt.balanceOf(noTokenId, address(vault)), 400e6, "vault should hold the transferred NO tokens");
        assertEq(mockCt.balanceOf(noTokenId, holder), 600e6, "holder balance should be debited");
    }

    // SC-3WLL: the hook returns the ERC-1155 single-transfer acknowledgement value
    function test_onERC1155ReceivedReturnsMagicValue() public {
        vm.prank(address(mockCt));
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
        mockCt.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");

        assertEq(mockCt.balanceOf(yesTokenId, address(vault)), 300e6, "vault should hold the transferred YES tokens");
        assertEq(mockCt.balanceOf(noTokenId, address(vault)), 200e6, "vault should hold the transferred NO tokens");
    }

    // SC-3WLM: the batch hook returns the ERC-1155 batch-transfer acknowledgement value
    function test_onERC1155BatchReceivedReturnsMagicValue() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId;
        ids[1] = noTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300e6;
        amounts[1] = 200e6;

        vm.prank(address(mockCt));
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
        mockCt.safeTransferFrom(holder, address(vault), yesTokenId, 100e6, "");
        mockCt.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");
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
contract VaultRejectsForeignERC1155Test is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockConditionalTokens mockCt;
    ForeignERC1155 foreignToken;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address stranger = makeAddr("stranger");

    bytes32 marketId = bytes32(uint256(1));
    uint256 foreignTokenId = uint256(keccak256("SOME OTHER MARKET"));

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        foreignToken = new ForeignERC1155();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, noTokenId));
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
// SC-5XY6: Receiver hook rejects a token id outside the vault's market
// What: Even when the caller IS the vault's own ConditionalTokens contract — so the
//       SC-3WLN caller guard passes — a transfer of any id other than yesTokenId or
//       noTokenId is rejected, and a batch is rejected whole if any element is foreign.
// Why:  One ConditionalTokens contract carries every market's tokens, so a correct
//       caller is not yet a correct token. This is what lets the blanket
//       setApprovalForAll the vault grants the exchange rest on an enforced check
//       rather than on "no entry point exists for foreign token IDs".
// Example: a holder tries to send the vault an outcome token of a different market's
//          condition → the transfer reverts UnknownTokenId and the vault's balance
//          for that id stays zero.
// ──────────────────────────────────────────────
contract VaultRejectsForeignTokenIdTest is Test {
    LPVaultFactory factory;
    LPVault vault;
    MockERC20 mockUsdc;
    MockConditionalTokens mockCt;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address holder = makeAddr("holder");

    bytes32 marketId = bytes32(uint256(1));
    bytes32 conditionId = keccak256("PROPHET-MARKET-A-CONDITION");
    bytes32 otherConditionId = keccak256("PROPHET-MARKET-B-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;
    uint256 foreignTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000), conditionId, yesTokenId, noTokenId));

        // A real outcome token of a different market, living on the same CT contract
        (foreignTokenId,) = mockCt.idsFor(address(mockUsdc), otherConditionId);

        mockCt.mint(holder, yesTokenId, 1_000e6);
        mockCt.mint(holder, noTokenId, 1_000e6);
        mockCt.mint(holder, foreignTokenId, 1_000e6);
    }

    // SC-5XY6: a single transfer of a foreign id from the vault's own CT reverts,
    // so the transfer never settles
    function test_revertsOnForeignTokenIdSingleTransfer() public {
        vm.prank(holder);
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        mockCt.safeTransferFrom(holder, address(vault), foreignTokenId, 500e6, "");
    }

    // SC-5XY6: the foreign token never lands in the vault
    function test_foreignTokenBalanceStaysZero() public {
        vm.prank(holder);
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        mockCt.safeTransferFrom(holder, address(vault), foreignTokenId, 500e6, "");

        assertEq(mockCt.balanceOf(foreignTokenId, address(vault)), 0, "vault must hold none of the foreign token");
        assertEq(mockCt.balanceOf(foreignTokenId, holder), 1_000e6, "holder's foreign balance is untouched");
    }

    // SC-5XY6: a batch is rejected whole when any element is foreign, even though its
    // other element is one of the vault's own ids
    function test_revertsOnBatchContainingForeignTokenId() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId;
        ids[1] = foreignTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300e6;
        amounts[1] = 200e6;

        vm.prank(holder);
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        mockCt.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");
    }

    // SC-5XY6: the valid leg of a rejected batch does not settle either — the whole
    // transfer reverts, so neither balance moves
    function test_validLegOfRejectedBatchDoesNotSettle() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = yesTokenId;
        ids[1] = foreignTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300e6;
        amounts[1] = 200e6;

        vm.prank(holder);
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        mockCt.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");

        assertEq(mockCt.balanceOf(yesTokenId, address(vault)), 0, "the valid leg must not settle when the batch fails");
        assertEq(mockCt.balanceOf(foreignTokenId, address(vault)), 0, "the foreign leg must not settle");
    }

    // SC-5XY6: a foreign id ordered first is caught too — the check is on every element,
    // not just a spot check of one position in the batch
    function test_revertsWhenForeignTokenIdIsFirstInBatch() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = foreignTokenId;
        ids[1] = noTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 200e6;
        amounts[1] = 300e6;

        vm.prank(holder);
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        mockCt.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");
    }

    // SC-5XY6: calling the hook directly with a foreign id is rejected on the id, not
    // on the caller — the CT itself is the caller here, so NotConditionalTokens does
    // not apply and only the new id check can reject it
    function test_directHookCallWithForeignIdRevertsOnTheId() public {
        vm.prank(address(mockCt));
        vm.expectRevert(LPVault.UnknownTokenId.selector);
        IERC1155Receiver(address(vault)).onERC1155Received(holder, holder, foreignTokenId, 1e6, "");
    }
}

// ──────────────────────────────────────────────
// SC-3WLO: Vault reports ERC-1155 receiver interface support
// What: supportsInterface returns true for IERC1155Receiver and for ERC-165 itself,
//       and false for anything else.
// Why:  Some callers ERC-165-probe a recipient before transferring. Without a truthful
//       answer they skip the transfer entirely, even though the hooks work.
// Example: supportsInterface(0x4e2312e0) == true, supportsInterface(0xffffffff) == false.
// ──────────────────────────────────────────────
contract VaultSupportsInterfaceTest is Test {
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        LPVaultFactory factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId)
        );
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
contract VaultOperatorDelegationTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId)
        );
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
contract VaultOracleDelegationTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId)
        );
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
contract VaultAdminDelegationTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId)
        );
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
contract VaultNoLocalRoleStateTest is Test {
    LPVaultFactory factory;
    LPVault vault;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");

    // The market's outcome-token identity, derived from the condition the vault names.
    bytes32 conditionId = keccak256("PROPHET-MARKET-CONDITION");
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        (yesTokenId, noTokenId) = mockCt.idsFor(address(mockUsdc), conditionId);
        vm.prank(oracleAddr);
        vault = LPVault(
            factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000), conditionId, yesTokenId, noTokenId)
        );
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
