// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev Test-only stand-in for the position-id derivation the Gnosis ConditionalTokens
///      contract performs. Inherited by every MockConditionalTokens in the suite so the
///      derivation lives in exactly one place.
///
///      `getPositionId` uses the real contract's formula verbatim. `getCollectionId` is a
///      keccak stand-in for the real contract's alt_bn128 point arithmetic — sound here
///      because the vault only ever compares what the CT returns against what the Oracle
///      passed in, so the derivation's internals are the CTF's business, not the vault's.
///      Verifying the real derivation needs a forked-Polygon test against the deployed
///      ConditionalTokens; see the plan's deferred note.
abstract contract CTFPositionIds {
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(parentCollectionId, conditionId, indexSet));
    }

    function getPositionId(address collateralToken, bytes32 collectionId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }

    /// @dev The YES/NO pair a vault for `conditionId` must be created with. Index set 1 is
    ///      taken as YES and index set 2 as NO by convention — the vault verifies the pair
    ///      as a set, so which one a caller labels YES is the caller's choice.
    function idsFor(address collateralToken, bytes32 conditionId) public pure returns (uint256 yes, uint256 no) {
        yes = getPositionId(collateralToken, getCollectionId(bytes32(0), conditionId, 1));
        no = getPositionId(collateralToken, getCollectionId(bytes32(0), conditionId, 2));
    }
}
