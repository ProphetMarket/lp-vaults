// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ1: Create Vault for Market
// Integration tests for every scenario in this use case.
// Covers: SC-REQ6, SC-REQ7, SC-REQ8, SC-REQ9, SC-REQA, SC-RG74, SC-RG75, SC-RG76, SC-RG77

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../src/LPVault.sol";

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
contract MockConditionalTokens {
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
                int24(20),
                address(this),
                uint128(2000),
                1
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
                int24(10),
                address(factory), // declared factory address that msg.sender doesn't match
                uint128(1000),
                1
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

    // Realistic CTF position ids for the two outcomes of one market
    uint256 yesTokenId = uint256(keccak256("YES"));
    uint256 noTokenId = uint256(keccak256("NO"));

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000)));

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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        mockCt = new MockConditionalTokens();
        foreignToken = new ForeignERC1155();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(marketId, int24(10), uint128(1000)));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        LPVaultFactory factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000)));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000)));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000)));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000)));
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

    function setUp() public {
        LPVault impl = new LPVault();
        MockERC20 mockUsdc = new MockERC20();
        MockConditionalTokens mockCt = new MockConditionalTokens();
        factory = new LPVaultFactory(
            address(impl), address(mockUsdc), makeAddr("exchange"), address(mockCt), admin, oracleAddr, operatorAddr
        );
        vm.prank(oracleAddr);
        vault = LPVault(factory.createVault(bytes32(uint256(1)), int24(10), uint128(1000)));
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
