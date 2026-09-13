// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Shared test fixture: writes LPVault storage fields that no entry point sets on demand.
// Test files import it. src/ never does.

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/// @dev Each write goes through forge-std stdStorage, which finds the slot at run time by
///      probing the public getter, so a storage layout change in src/LPVault.sol changes
///      nothing here. `depth` selects the word of the getter's return tuple.
library VaultStorage {
    using stdStorage for StdStorage;

    /// @dev Overwrites positions[positionId].feeGrowthInsideLastX128, the sixth field of a Position.
    function setFeeGrowthInsideLast(StdStorage storage store, address vault, uint256 positionId, uint256 value)
        internal
    {
        store.target(vault).sig("positions(uint256)").with_key(positionId).depth(5).checked_write(value);
    }

    /// @dev Overwrites ticks[tick].feeGrowthOutsideX128, the third field of a TickInfo.
    function setFeeGrowthOutside(StdStorage storage store, address vault, int24 tick, uint256 value) internal {
        // A mapping key of type int24 is the sign-extended 32-byte word, as abi.encode produces it.
        // casting to 'uint256' is safe because the two's complement bit pattern is the key itself
        // forge-lint: disable-next-line(unsafe-typecast)
        store.target(vault).sig("ticks(int24)").with_key(bytes32(uint256(int256(tick)))).depth(2).checked_write(value);
    }

    /// @dev Overwrites currentTick. The write moves no liquidity: `activeLiquidity` and every
    ///      tick record stay as they are, so a test calls it only when no position is in range at
    ///      the old tick and none at the new tick. Otherwise the next crossing runs `_addDelta` on
    ///      a stale `activeLiquidity` and reverts `SafeCastOverflow` for a reason unrelated to the
    ///      search. It exists so a search test can start inside an extreme bitmap word: a real
    ///      move from 0 to 8,388,000 reads 32,766 words, which is the large jump that NFR-5IDG
    ///      leaves to chunking.
    function setCurrentTick(StdStorage storage store, address vault, int24 tick) internal {
        // The slot holds the sign-extended word, so a negative tick reads back as written.
        // casting to 'uint256' is safe because the two's complement bit pattern is the stored word
        // forge-lint: disable-next-line(unsafe-typecast)
        store.target(vault).sig("currentTick()").checked_write(bytes32(uint256(int256(tick))));
    }
}
