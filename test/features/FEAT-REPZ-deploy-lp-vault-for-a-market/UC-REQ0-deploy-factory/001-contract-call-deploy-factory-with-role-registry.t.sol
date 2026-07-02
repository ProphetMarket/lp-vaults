// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// UC-REQ0: Deploy Factory
// SLICE-001: deploy-factory-with-role-registry

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../../../src/LPVaultFactory.sol";
import {LPVault} from "../../../../src/LPVault.sol";

// ──────────────────────────────────────────────
// Minimal mocks — stub the ERC-20 and ERC-1155 entry points that
// LPVault.initialize() calls (approve, setApprovalForAll). The T-002
// slice extended initialize() with those external calls, so any test
// that initializes a clone must pass real contract addresses for usdc
// and conditionalTokens.
// ──────────────────────────────────────────────

contract MockERC20 {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MockConditionalTokens {
    function setApprovalForAll(address, bool) external {}
}

// ──────────────────────────────────────────────
// Test harnesses — expose modifier-gated entry points so the modifier
// bodies (onlyAdmin, onlyOperator, onlyOracle, onlyFactory) are exercisable
// in isolation. These are test-only; the real gated functions arrive in T-002/T-003.
// ──────────────────────────────────────────────

contract LPVaultFactoryHarness is LPVaultFactory {
    constructor(
        address implementation_,
        address usdc_,
        address exchange_,
        address conditionalTokens_,
        address admin_,
        address oracle_,
        address operator_
    ) LPVaultFactory(implementation_, usdc_, exchange_, conditionalTokens_, admin_, oracle_, operator_) {}

    function guardedByAdmin() external onlyAdmin {}
    function guardedByOperator() external onlyOperator {}
    function guardedByOracle() external onlyOracle {}
}

contract LPVaultHarness is LPVault {
    function guardedByFactory() external onlyFactory {}
    function guardedByAdmin() external onlyAdmin {}
    function guardedByOperator() external onlyOperator {}
    function guardedByOracle() external onlyOracle {}
}

// SC-REQ3: Successful deployment with valid parameters
// What: Deploying the factory with valid, distinct role addresses initializes
//       the full Auth registry and stores all external contract addresses.
// Why:  The factory is the root of trust — every vault clone inherits its
//       registry at initialize() time. If the constructor doesn't set roles
//       and addresses correctly, every downstream operation is compromised.
// Example: constructor(impl, usdc, exchange, ct, admin, oracle, operator)
//          with oracle != operator
//          → admins[admin]==1, adminCount==1, oracle stored, operators[operator]==1,
//          all four immutable addresses queryable.
contract DeployFactorySuccessTest is Test {
    LPVaultFactory factory;
    LPVault impl;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address usdcAddr = makeAddr("usdc");
    address exchangeAddr = makeAddr("exchange");
    address ctAddr = makeAddr("conditionalTokens");

    function setUp() public {
        // Deploy a real LPVault implementation — its constructor calls
        // _disableInitializers(), locking it from direct initialization.
        impl = new LPVault();

        // Deploy the factory with all seven addresses
        factory = new LPVaultFactory(address(impl), usdcAddr, exchangeAddr, ctAddr, admin, oracleAddr, operatorAddr);
    }

    // SC-REQ3: admins[initialAdmin] == 1
    function test_initialAdminIsRegistered() public view {
        assertEq(factory.admins(admin), 1, "admin should be registered with value 1");
    }

    // SC-REQ3: adminCount == 1
    function test_adminCountIsOne() public view {
        assertEq(factory.adminCount(), 1, "exactly one admin at deployment");
    }

    // SC-REQ3: oracle == initialOracle
    function test_oracleIsSet() public view {
        assertEq(factory.oracle(), oracleAddr, "oracle should match constructor arg");
    }

    // SC-REQ3: operators[initialOperator] == 1
    function test_initialOperatorIsRegistered() public view {
        assertEq(factory.operators(operatorAddr), 1, "operator should be registered with value 1");
    }

    // SC-REQ3: implementation returns the LPVault implementation address
    function test_implementationAddressIsStored() public view {
        assertEq(factory.implementation(), address(impl), "implementation should match deployed LPVault");
    }

    // SC-REQ3: usdc returns the USDC address
    function test_usdcAddressIsStored() public view {
        assertEq(factory.usdc(), usdcAddr, "usdc should match constructor arg");
    }

    // SC-REQ3: exchange returns the exchange address
    function test_exchangeAddressIsStored() public view {
        assertEq(factory.exchange(), exchangeAddr, "exchange should match constructor arg");
    }

    // SC-REQ3: conditionalTokens returns the ConditionalTokens address
    function test_conditionalTokensAddressIsStored() public view {
        assertEq(factory.conditionalTokens(), ctAddr, "conditionalTokens should match constructor arg");
    }
}

// SC-REQ4: Deployment reverts when oracle equals operator
// What: The constructor enforces that oracle and operator addresses are distinct,
//       reverting with RoleSeparation if they match.
// Why:  Oracle and Operator are separate trust domains (CLAUDE.md hard rule,
//       NFR-RER1). Compromise of one must not unlock the other's powers.
//       The constructor is the first enforcement point for this invariant.
// Example: constructor(..., oracle=0xABC, operator=0xABC) → revert RoleSeparation.
contract DeployFactoryOracleEqualsOperatorTest is Test {
    // SC-REQ4: deployment reverts when oracle == operator
    function test_revertsWhenOracleEqualsOperator() public {
        LPVault impl = new LPVault();
        address admin = makeAddr("admin");
        address sameAddr = makeAddr("sameAddr");

        vm.expectRevert(LPVaultFactory.RoleSeparation.selector);
        new LPVaultFactory(
            address(impl),
            makeAddr("usdc"),
            makeAddr("exchange"),
            makeAddr("ct"),
            admin,
            sameAddr, // oracle
            sameAddr // operator — same address triggers RoleSeparation
        );
    }
}

// SC-REQ5: Clone IS initializable (positive counterpart to SC-REQ5)
// What: A freshly-deployed EIP-1167 clone of LPVault CAN be initialized,
//       proving that _disableInitializers() only locks the implementation
//       and that the initialize() function correctly stores all parameters.
// Why:  SC-REQ5 proves the negative path (implementation locked). This test
//       proves the positive path: clones start with _initialized = false
//       (default storage) so the initializer modifier allows the first call.
//       Also validates that factory is derived from msg.sender.
// Example: create minimal proxy of impl → call initialize() → all storage set.
contract CloneInitializeSuccessTest is Test {
    // SC-REQ5: clone initializes successfully (positive counterpart)
    function test_cloneCanBeInitialized() public {
        LPVault impl = new LPVault();
        address clone = _createClone(address(impl));
        LPVault vault = LPVault(clone);

        bytes32 mktId = bytes32(uint256(42));
        address usdcAddr = address(new MockERC20());
        address exchangeAddr = makeAddr("exchange");
        address ctAddr = address(new MockConditionalTokens());
        int24 spacing = int24(10);
        uint128 minLiq = uint128(1000);

        // Deploy real factory so vault delegation works (FR-FKD0/1/2)
        LPVaultFactory realFactory = new LPVaultFactory(
            address(impl), usdcAddr, exchangeAddr, ctAddr, makeAddr("admin"), makeAddr("oracle"), makeAddr("operator")
        );

        vm.prank(address(realFactory));
        vault.initialize(mktId, usdcAddr, exchangeAddr, ctAddr, spacing, address(realFactory), minLiq);

        assertEq(vault.factory(), address(realFactory), "factory should be the real factory");
        assertEq(vault.marketId(), mktId, "marketId should match");
        assertEq(vault.usdc(), usdcAddr, "usdc should match");
        assertEq(vault.exchange(), exchangeAddr, "exchange should match");
        assertEq(vault.conditionalTokens(), ctAddr, "conditionalTokens should match");
        assertEq(vault.oracle(), makeAddr("oracle"), "oracle should delegate to factory");
        assertEq(vault.tickSpacing(), spacing, "tickSpacing should match");
        assertEq(vault.minimumFirstLiquidity(), minLiq, "minimumFirstLiquidity should match");
    }

    // SC-REQ5: clone cannot be initialized twice
    function test_cloneCannotBeInitializedTwice() public {
        LPVault impl = new LPVault();
        address clone = _createClone(address(impl));
        LPVault vault = LPVault(clone);

        address usdc1 = address(new MockERC20());
        address ct1 = address(new MockConditionalTokens());
        address usdc2 = address(new MockERC20());
        address ct2 = address(new MockConditionalTokens());

        // Deploy real factory so vault delegation works
        LPVaultFactory realFactory = new LPVaultFactory(
            address(impl), usdc1, makeAddr("exchange"), ct1, makeAddr("admin"), makeAddr("oracle"), makeAddr("operator")
        );

        vm.prank(address(realFactory));
        vault.initialize(
            bytes32(uint256(1)), usdc1, makeAddr("exchange"), ct1, int24(10), address(realFactory), uint128(1000)
        );

        vm.prank(address(realFactory));
        vm.expectRevert(LPVault.AlreadyInitialized.selector);
        vault.initialize(
            bytes32(uint256(2)), usdc2, makeAddr("exchange2"), ct2, int24(20), address(realFactory), uint128(2000)
        );
    }

    /// @dev Deploys an EIP-1167 minimal proxy clone of the given implementation.
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

// SC-REQ5: Implementation contract is not directly initializable
// What: Calling initialize() on the LPVault implementation (not a clone) reverts
//       because the constructor called _disableInitializers(), which sets
//       _initialized = true before any external caller can reach initialize().
// Why:  EIP-1167 clones share the implementation's bytecode. If the implementation
//       were initializable, an attacker could call initialize() on it with
//       malicious parameters. Although the implementation's storage is separate
//       from clones', allowing initialization breaks the trust model.
// Example: new LPVault() → impl.initialize(...) → revert AlreadyInitialized.
contract ImplementationNotInitializableTest is Test {
    // SC-REQ5: initialize() on implementation reverts with AlreadyInitialized
    function test_revertsWhenInitializeCalledOnImplementation() public {
        // Deploy the implementation — constructor calls _disableInitializers()
        LPVault impl = new LPVault();

        // Any call to initialize() should revert because _initialized is already true
        vm.expectRevert(LPVault.AlreadyInitialized.selector);
        impl.initialize(
            bytes32(uint256(1)),
            makeAddr("usdc"),
            makeAddr("exchange"),
            makeAddr("ct"),
            int24(10),
            address(this),
            uint128(1000)
        );
    }
}

// ──────────────────────────────────────────────
// Modifier coverage: verify the exported modifiers (onlyAdmin, onlyOperator,
// onlyOracle, onlyFactory) revert for unauthorized callers and pass for
// authorized ones. These modifiers are in the slice's `provides` list.
// ──────────────────────────────────────────────

// What: Each Auth modifier on LPVaultFactory reverts with the correct custom
//       error when called by an unauthorized address, and passes silently
//       when called by the authorized address.
// Why:  The modifiers are exported (provides) and downstream slices depend
//       on them working. Testing them here proves the inlined Auth pattern
//       is wired correctly at the storage level.
contract FactoryModifierTest is Test {
    LPVaultFactoryHarness factory;

    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address nobody = makeAddr("nobody");

    function setUp() public {
        LPVault impl = new LPVault();
        factory = new LPVaultFactoryHarness(
            address(impl), makeAddr("usdc"), makeAddr("exchange"), makeAddr("ct"), admin, oracleAddr, operatorAddr
        );
    }

    function test_onlyAdminRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotAdmin.selector);
        factory.guardedByAdmin();
    }

    function test_onlyAdminPassesForAdmin() public {
        vm.prank(admin);
        factory.guardedByAdmin();
    }

    function test_onlyOperatorRevertsForNonOperator() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotOperator.selector);
        factory.guardedByOperator();
    }

    function test_onlyOperatorPassesForOperator() public {
        vm.prank(operatorAddr);
        factory.guardedByOperator();
    }

    function test_onlyOracleRevertsForNonOracle() public {
        vm.prank(nobody);
        vm.expectRevert(LPVaultFactory.NotOracle.selector);
        factory.guardedByOracle();
    }

    function test_onlyOraclePassesForOracle() public {
        vm.prank(oracleAddr);
        factory.guardedByOracle();
    }
}

// What: Each Auth modifier on LPVault (plus onlyFactory) reverts with the
//       correct custom error for unauthorized callers. Tests run against
//       a clone so the vault is in initialized state with a known registry.
// Why:  The vault's modifiers are also exported (provides). A clone starts
//       with zero storage, so we initialize it first to set up the registry.
contract VaultModifierTest is Test {
    LPVaultHarness vault;

    address factoryAddr;
    address admin = makeAddr("admin");
    address oracleAddr = makeAddr("oracle");
    address operatorAddr = makeAddr("operator");
    address nobody = makeAddr("nobody");

    LPVaultFactory realFactory;

    function setUp() public {
        // Deploy a harness as the implementation
        LPVaultHarness implHarness = new LPVaultHarness();

        // Create clone of the harness
        address clone = _createClone(address(implHarness));
        vault = LPVaultHarness(clone);

        // Deploy real factory so vault modifier delegation works (FR-FKD0/1/2)
        address usdcAddr = address(new MockERC20());
        address ctAddr = address(new MockConditionalTokens());
        realFactory = new LPVaultFactory(
            address(implHarness), usdcAddr, makeAddr("exchange"), ctAddr, admin, oracleAddr, operatorAddr
        );

        // Initialize the clone from the real factory's address
        vm.prank(address(realFactory));
        LPVault(clone)
            .initialize(
                bytes32(uint256(1)),
                usdcAddr,
                makeAddr("exchange"),
                ctAddr,
                int24(10),
                address(realFactory),
                uint128(1000)
            );
        factoryAddr = address(realFactory);
    }

    function test_onlyFactoryRevertsForNonFactory() public {
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotFactory.selector);
        vault.guardedByFactory();
    }

    function test_onlyFactoryPassesForFactory() public {
        vm.prank(factoryAddr);
        vault.guardedByFactory();
    }

    function test_onlyOracleRevertsForNonOracle() public {
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotOracle.selector);
        vault.guardedByOracle();
    }

    function test_onlyOraclePassesForOracle() public {
        vm.prank(oracleAddr);
        vault.guardedByOracle();
    }

    // The vault-side admin/operator modifiers are inlined from the Auth pattern
    // but no production vault function currently uses them. The factory never
    // grants vault-level admin/operator, so only the revert side is reachable
    // without vm.store-seeding the clone's mappings. Exercising the revert side
    // here covers the modifier branch and locks the NotAdmin/NotOperator
    // selectors against silent regressions in the inlined Auth scaffolding.
    function test_onlyAdminRevertsForNonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotAdmin.selector);
        vault.guardedByAdmin();
    }

    function test_onlyOperatorRevertsForNonOperator() public {
        vm.prank(nobody);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.guardedByOperator();
    }

    /// @dev Deploys an EIP-1167 minimal proxy clone of the given implementation.
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
