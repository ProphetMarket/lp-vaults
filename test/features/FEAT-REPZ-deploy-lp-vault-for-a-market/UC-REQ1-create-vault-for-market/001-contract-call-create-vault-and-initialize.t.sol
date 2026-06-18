// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ1: Create Vault for Market
// SLICE-001: create-vault-and-initialize

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

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

contract MockConditionalTokens {
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
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

    // Event re-declared so we can use vm.expectEmit on it
    event VaultCreated(bytes32 indexed marketId, address vault, uint128 minimumFirstLiquidity);

    function setUp() public {
        impl = new LPVault();
        mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), exchangeAddr, address(mockCt), admin, oracleAddr, operatorAddr
        );
    }

    // SC-REQ6: vaultForMarket returns non-zero clone address
    function test_vaultForMarketReturnsCloneAddress() public {
        vm.prank(oracleAddr);
        address vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
        assertTrue(vault != address(0), "vault address should be non-zero");
        assertEq(factory.vaultForMarket(marketId), vault, "registry should map marketId to vault");
    }

    // SC-REQ6: clone's marketId matches
    function test_cloneMarketIdMatches() public {
        vm.prank(oracleAddr);
        address vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
        assertEq(LPVault(vault).marketId(), marketId, "clone marketId should match");
    }

    // SC-REQ6: clone's usdc, exchange, conditionalTokens, oracle, tickSpacing, factory match factory values
    function test_cloneConfigMatchesFactoryValues() public {
        vm.prank(oracleAddr);
        address vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
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
        address vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
        assertEq(LPVault(vault).minimumFirstLiquidity(), minimumFirstLiquidity, "minimumFirstLiquidity should match");
    }

    // SC-REQ6: clone's phase == Active (1)
    function test_clonePhaseIsActive() public {
        vm.prank(oracleAddr);
        address vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
        assertEq(LPVault(vault).phase(), uint8(1), "phase should be Active (1)");
    }

    // SC-REQ6: clone's activeLiquidity == 0
    function test_cloneActiveLiquidityIsZero() public {
        vm.prank(oracleAddr);
        address vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
        assertEq(LPVault(vault).activeLiquidity(), uint128(0), "activeLiquidity should start at 0");
    }

    // SC-REQ6: USDC.allowance(vault, exchange) == type(uint256).max
    function test_usdcApprovalIsMaxOnExchange() public {
        vm.prank(oracleAddr);
        address vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
        assertEq(mockUsdc.allowance(vault, exchangeAddr), type(uint256).max, "USDC allowance should be max");
    }

    // SC-REQ6: ConditionalTokens.isApprovedForAll(vault, exchange) == true
    function test_conditionalTokensApprovalOnExchange() public {
        vm.prank(oracleAddr);
        address vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
        assertTrue(mockCt.isApprovedForAll(vault, exchangeAddr), "CT should be approvedForAll on exchange");
    }

    // SC-REQ6: VaultCreated event is emitted with correct args
    function test_emitsVaultCreatedEvent() public {
        // Pre-compute the expected clone address: first deployment from factory's nonce 1
        address expectedVault = computeCreateAddress(address(factory), 1);

        vm.expectEmit(true, false, false, true, address(factory));
        emit VaultCreated(marketId, expectedVault, minimumFirstLiquidity);

        vm.prank(oracleAddr);
        factory.createVault(marketId, tickSpacing, minimumFirstLiquidity);
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
    }

    // SC-REQ7: second createVault with same marketId reverts DuplicateMarket
    function test_revertsOnDuplicateMarketId() public {
        vm.prank(oracleAddr);
        factory.createVault(marketId, int24(10), uint128(1000));

        vm.prank(oracleAddr);
        vm.expectRevert(LPVaultFactory.DuplicateMarket.selector);
        factory.createVault(marketId, int24(10), uint128(1000));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
    }

    // SC-REQ8: operator calling createVault reverts NotOracle
    function test_revertsWhenOperatorCallsCreateVault() public {
        vm.prank(operatorAddr);
        vm.expectRevert(LPVaultFactory.NotOracle.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000));
    }

    // SC-REQ8: admin calling createVault reverts NotOracle
    function test_revertsWhenAdminCallsCreateVault() public {
        vm.prank(admin);
        vm.expectRevert(LPVaultFactory.NotOracle.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000));
    }

    // SC-REQ8: arbitrary address calling createVault reverts NotOracle
    function test_revertsWhenNobodyCallsCreateVault() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotOracle.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
    }

    // SC-REQ9: calling initialize on an already-initialized clone reverts AlreadyInitialized
    function test_revertsOnDoubleInitialize() public {
        vm.prank(oracleAddr);
        address vault = factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000));

        // Any caller hitting initialize() on the already-initialized clone reverts
        vm.expectRevert(LPVault.AlreadyInitialized.selector);
        LPVault(vault)
            .initialize(
                bytes32(uint256(2)),
                makeAddr("usdc2"),
                makeAddr("exchange2"),
                makeAddr("ct2"),
                makeAddr("oracle2"),
                int24(20),
                address(this),
                uint128(2000),
                makeAddr("admin2"),
                makeAddr("operator2")
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
                makeAddr("oracle"),
                int24(10),
                address(factory), // declared factory address that msg.sender doesn't match
                uint128(1000),
                makeAddr("admin"),
                makeAddr("operator")
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
    }

    // SC-RG74: createVault with minimumFirstLiquidity == 0 reverts ZeroFloor
    function test_revertsOnZeroMinimumFirstLiquidity() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVaultFactory.ZeroFloor.selector);
        factory.createVault(bytes32(uint256(1)), int24(10), uint128(0));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), initialMin));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000)));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000)));
    }

    // SC-RG77: oracle calling setMinimumFirstLiquidity(0) reverts ZeroFloor
    function test_revertsOnZeroNewMin() public {
        vm.prank(oracleAddr);
        vm.expectRevert(LPVault.ZeroFloor.selector);
        vault.setMinimumFirstLiquidity(uint128(0));
    }
}
