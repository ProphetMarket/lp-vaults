// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-REPZ: Deploy LP Vault for a Market
// UC-REQ1: Create Vault for Market
// FEAT-6HBN: Complete-Set Merge and Resolution Redemption
// FEAT-7G40: Burn LP Position
// Shared test fixture: the real Gnosis ConditionalTokens bytecode and the helpers that
// prepare a binary condition, create a vault with a verified outcome-token identity, and
// fund a vault with outcome tokens.
// Test files import it. src/ never does.

import {Test} from "forge-std/Test.sol";
import {LPVaultFactory} from "../../src/LPVaultFactory.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev The ConditionalTokens functions the tests call directly. The factory and the vault reach
///      the same contract through the inline interface in src/LPVault.sol, which declares only
///      the calls the production code makes.
interface ITestConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function splitPosition(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256);
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function setApprovalForAll(address operator, bool approved) external;
}

/// @dev Base for every test that creates a vault. The factory verifies the outcome-token identity
///      against the real ConditionalTokens contract at createVault(), so a mock would test the mock.
abstract contract ConditionalTokensFixture is Test {
    /// @dev Vendored build of the Gnosis ConditionalTokens contract. foundry.toml grants read
    ///      access to this folder only.
    string internal constant CONDITIONAL_TOKENS_ARTIFACT = "lib/ctf-exchange/artifacts/ConditionalTokens.json";

    ITestConditionalTokens internal ctf;

    /// @dev Deploys the real ConditionalTokens bytecode and keeps it in `ctf`.
    function _deployConditionalTokens() internal returns (ITestConditionalTokens) {
        ctf = ITestConditionalTokens(deployCode(CONDITIONAL_TOKENS_ARTIFACT));
        return ctf;
    }

    /// @dev Prepares a 2-outcome condition with this test contract as the condition's oracle, and
    ///      returns the identity createVault needs: index set 1 is YES and index set 2 is NO.
    function _prepareBinaryCondition(bytes32 questionId, address collateral)
        internal
        returns (bytes32 conditionId, uint256 yesTokenId, uint256 noTokenId)
    {
        ctf.prepareCondition(address(this), questionId, 2);
        conditionId = ctf.getConditionId(address(this), questionId, 2);
        yesTokenId = ctf.getPositionId(collateral, ctf.getCollectionId(bytes32(0), conditionId, 1));
        noTokenId = ctf.getPositionId(collateral, ctf.getCollectionId(bytes32(0), conditionId, 2));
    }

    /// @dev Prepares a binary condition whose question ID is `marketId`, then has the Oracle create
    ///      the vault with that condition's identity.
    function _createVault(
        LPVaultFactory factory,
        address oracle,
        bytes32 marketId,
        int24 tickSpacing,
        uint128 minimumFirstLiquidity
    ) internal returns (address vault) {
        (bytes32 conditionId, uint256 yesTokenId, uint256 noTokenId) = _prepareBinaryCondition(marketId, factory.usdc());
        collateralOf[conditionId] = factory.usdc();
        vm.prank(oracle);
        vault = factory.createVault(marketId, tickSpacing, minimumFirstLiquidity, conditionId, yesTokenId, noTokenId);
    }

    /// @dev Gives `holder` `amount` YES and `amount` NO tokens by splitting USDC through the real contract.
    function _mintCompleteSets(MockERC20 usdc, address holder, bytes32 conditionId, uint256 amount) internal {
        usdc.mint(holder, amount);
        vm.startPrank(holder);
        usdc.approve(address(ctf), amount);
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, _binaryPartition(), amount);
        vm.stopPrank();
    }

    /// @dev Gives `vault` `yesAmount` YES and `noAmount` NO, so a burn's token leg and the merge
    ///      run against real balances. Splits max(yesAmount, noAmount) USDC to a throwaway holder
    ///      through _mintCompleteSets, then transfers the asked amounts to the vault; the holder
    ///      keeps the rest. The vault's receiver hook accepts its own two token IDs.
    function _giveOutcomeTokens(address vault, bytes32 conditionId, uint256 yesAmount, uint256 noAmount) internal {
        uint256 amount = yesAmount > noAmount ? yesAmount : noAmount;
        if (amount == 0) return;
        address holder = makeAddr("outcome-token-holder");
        MockERC20 usdc = MockERC20(_collateralOf(conditionId));
        _mintCompleteSets(usdc, holder, conditionId, amount);
        uint256 yesId = ctf.getPositionId(address(usdc), ctf.getCollectionId(bytes32(0), conditionId, 1));
        uint256 noId = ctf.getPositionId(address(usdc), ctf.getCollectionId(bytes32(0), conditionId, 2));
        vm.startPrank(holder);
        if (yesAmount > 0) ctf.safeTransferFrom(holder, vault, yesId, yesAmount, "");
        if (noAmount > 0) ctf.safeTransferFrom(holder, vault, noId, noAmount, "");
        vm.stopPrank();
    }

    /// @dev The collateral each prepared condition was split against, recorded by _createVault
    ///      so _giveOutcomeTokens needs no extra argument.
    mapping(bytes32 => address) internal collateralOf;

    function _collateralOf(bytes32 conditionId) internal view returns (address) {
        return collateralOf[conditionId];
    }

    /// @dev The partition [1, 2]: YES then NO.
    function _binaryPartition() internal pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
    }
}
