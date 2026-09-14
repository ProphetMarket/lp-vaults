// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-TVS0: Update Tick and Cross Ticks (the planted extreme ticks)
// FEAT-6HBN: Complete-Set Merge and Resolution Redemption (the Cancelled phase)
// Shared test fixture: writes LPVault storage fields that no entry point sets on demand.
// Test files import it. src/ never does.

import {StdStorage, stdStorage, stdStorageSafe, FindData} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Each write goes through forge-std stdStorage, which finds the slot at run time by
///      probing the public getter, so a storage layout change in src/LPVault.sol changes
///      nothing here. `depth` selects the word of the getter's return tuple.
library VaultStorage {
    using stdStorage for StdStorage;

    /// @dev The cheatcode address, for the one raw write below.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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

    /// @dev Overwrites totalFeesOwedX128, the solvency ledger's fee total (FEAT-9BQZ). A test that
    ///      plants a wrapped fee snapshot gives a position a fee claim that no report credited, so
    ///      it credits the ledger here by the same amount, or the merge's checked dust debit
    ///      (FR-9BRH) would underflow on a claim the ledger never carried.
    function setTotalFeesOwedX128(StdStorage storage store, address vault, uint256 value) internal {
        store.target(vault).sig("totalFeesOwedX128()").checked_write(value);
    }

    /// @dev Overwrites phase. Used to reach the Cancelled phase where the tested function reads
    ///      only `phase`, because the real emergencyCancelAll needs a 7-day silence that the
    ///      emergency-cancel tests already prove.
    function setPhase(StdStorage storage store, address vault, uint8 phase) internal {
        // `phase` shares a slot with `_initialized` and `paused`, so the packed-slot mode
        // finds the byte inside the word and writes only that byte.
        store.enable_packed_slots().target(vault).sig("phase()").checked_write(uint256(phase));
    }

    /// @dev Plants an initialized tick: writes ticks[tick].liquidityGross, the first field of a
    ///      TickInfo, and sets the tick's bitmap bit, with no position behind it. The four
    ///      extreme-word search tests use it, because a mint is bounded to the price scale
    ///      [0, 10000] and cannot reach tick 8,388,590 (FEAT-T7AF FR-T7B2).
    function plantTick(StdStorage storage store, address vault, int24 tick, uint128 liquidityGross) internal {
        // casting to 'uint256' is safe because the two's complement bit pattern is the key itself
        // forge-lint: disable-next-line(unsafe-typecast)
        store.target(vault).sig("ticks(int24)").with_key(bytes32(uint256(int256(tick)))).depth(0)
            .checked_write(uint256(liquidityGross));

        // The same decomposition as LPVault._tickPosition: an arithmetic shift for the word and
        // the low eight bits for the position inside it.
        // casting to 'int16' is safe because an int24 shifted right by 8 fits in 16 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        int16 wordPos = int16(tick >> 8);
        // casting to 'uint8' is safe because the mask keeps eight bits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 bitPos = uint8(uint24(tick) & 0xff);
        // casting to 'uint256' is safe because the two's complement bit pattern is the key itself
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 key = bytes32(uint256(int256(wordPos)));
        uint256 word = store.target(vault).sig("tickBitmap(int16)").with_key(key).read_uint();
        // forge-lint: disable-next-line(incorrect-shift)
        store.target(vault).sig("tickBitmap(int16)").with_key(key).checked_write(word | (uint256(1) << bitPos));
    }

    /// @dev Overwrites currentTick. The write moves no liquidity: `activeLiquidity`, the ledger,
    ///      and every tick record stay as they are, so a test calls it only when no position is in
    ///      range at the old tick and none at the new tick. Otherwise the next crossing runs
    ///      `_addDelta` on a stale `activeLiquidity` and reverts `SafeCastOverflow` for a reason
    ///      unrelated to the search. It exists so a search test can start inside an extreme bitmap
    ///      word: a real move from 0 to 8,388,000 reads 32,766 words, which is the large jump that
    ///      NFR-5IDG leaves to chunking.
    ///      `currentTick` shares its slot with `noSideLiquidity` (FEAT-9BQZ), so the write goes
    ///      through the packed-slot finder and replaces only the tick's 24 bits; the counter keeps
    ///      its value, which the caller can read back as zero. The write is raw, because
    ///      `checked_write` compares the getter's sign-extended return with the 24-bit pattern it
    ///      wrote and rejects every negative tick.
    function setCurrentTick(StdStorage storage store, address vault, int24 tick) internal {
        FindData storage data = stdStorageSafe.find(store.enable_packed_slots().target(vault).sig("currentTick()"));
        bytes32 current = vm.load(vault, bytes32(data.slot));
        // casting to 'uint24' then 'uint256' is safe because the 24-bit two's complement pattern is
        // exactly the bits the slot stores for an int24, and the getter sign-extends it on the read
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 packed = uint256(uint24(tick));
        bytes32 updated = stdStorageSafe.getUpdatedSlotValue(current, packed, data.offsetLeft, data.offsetRight);
        vm.store(vault, bytes32(data.slot), updated);
    }
}
