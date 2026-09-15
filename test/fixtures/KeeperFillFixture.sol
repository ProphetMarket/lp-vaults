// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// FEAT-9BQZ: Vault Solvency Ledger (SC-DFDY, the conservation scenario)
// FEAT-6HBN: Complete-Set Merge and Resolution Redemption (SC-DFDV, SC-DFDW)
// FEAT-7G40: Burn LP Position (SC-DFDX)
// Shared test fixture: the keeper's drift-free fill for one tick move. The vault's holdings
// arrive the way fills bring them, not by donation, so a payout rule that is wrong for the claim
// model (finding CV-01 of audits/code-validation-round-1.md) cannot pass by consistency with
// itself (finding CV-02). Test files import it. src/ never does.

import {LPVault} from "../../src/LPVault.sol";
import {LPVaultFixture} from "./LPVaultFixture.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev The keeper is an external actor most vault tests never model, so this fixture stays out
///      of LPVaultFixture and only the tests that model fills inherit it.
abstract contract KeeperFillFixture is LPVaultFixture {
    /// @dev One tick is one basis point (PRICE_TICK_ONE in the vault).
    uint256 internal constant BPS = 10_000;

    /// @dev The house board quotes no bid below 100 bps and no level above 9,900 bps
    ///      (PriceFloorBps and PriceCeilingBps in the Prophet server), so no order rests on the
    ///      book outside this band and the callers keep every range inside it.
    uint256 internal constant BOARD_FLOOR_BPS = 100;
    uint256 internal constant BOARD_CEILING_BPS = 9_900;

    /// @dev The scale of a spend summed in liquidity units: units x LIQUIDITY_PRECISION x BPS.
    uint256 internal constant SPEND_SCALE = 1e18 * BPS;

    /// @dev The keeper's drift-free fill for one tick move: for every live position and every
    ///      level the move crosses inside its range, the vault buys liquidity / 1e18 tokens per
    ///      level, YES on a fall at the bid for t and NO on a rise at the bid for 10000 - t. The
    ///      bid is what the house board pays: its own probability less the board's split of
    ///      `spreadBps`, floored at 100 bps with the blocked margin moved across (quotes.Board,
    ///      internal/services/quotes/calculator.go in the Prophet server, commit 9bc0d28c), so
    ///      inside the band a bid is never above the model price. The USDC spend and the token
    ///      count are summed in scaled units and rounded once per asset per move, spend down and
    ///      tokens up, so rounding never leaves the vault short. The USDC leaves through the
    ///      exchange's standing approval and the tokens arrive through the receiver hook. The
    ///      caller keeps the vault's USDC at or above the spend the way the keeper does, by
    ///      merging on sight before the ladder: a level filled twice in the same direction with
    ///      no merge between holds its USDC as a pair. Returns the spread income of the move,
    ///      floor(model spend) - floor(bid spend) in USDC units, the model price less the bid
    ///      summed over every token bought, which the vault keeps above what the ledger owes
    ///      (FR-9BRP) for the income decision (O1b in audits/audit-fixes-ranged.md).
    /// @dev One move's sums in liquidity units: tokens as L per level, spends as L x bps per
    ///      level. A struct, because the per-position loop would otherwise exceed the stack.
    struct FillSums {
        uint256 tokensScaled;
        uint256 bidScaled;
        uint256 modelScaled;
    }

    function _fillMove(LPVault vault, address exchange, int24 from, int24 to, uint32 spreadBps)
        internal
        returns (uint256 spreadIncome)
    {
        if (from == to) return 0;
        bool falling = to < from;
        FillSums memory sums;
        uint256 count = vault.nextPositionId();
        for (uint256 i = 0; i < count; i++) {
            _sumPosition(sums, vault, i, falling ? to : from, falling ? from : to, falling, spreadBps);
        }
        if (sums.tokensScaled == 0) return 0;

        uint256 tokens = (sums.tokensScaled + 1e18 - 1) / 1e18;
        uint256 spend = sums.bidScaled / SPEND_SCALE;
        spreadIncome = sums.modelScaled / SPEND_SCALE - spend;

        // The USDC leaves through the exchange's standing approval, as a fill would (decision C8)
        if (spend > 0) {
            MockERC20 usdc = MockERC20(vault.usdc());
            vm.prank(exchange);
            assertTrue(usdc.transferFrom(address(vault), exchange, spend), "the fill should spend");
        }

        // The tokens arrive through the receiver hook
        _giveOutcomeTokens(address(vault), vault.conditionId(), falling ? tokens : 0, falling ? 0 : tokens);
    }

    /// @dev Adds one live position's crossed levels, [lo, hi) cut to its range, to `sums`.
    function _sumPosition(
        FillSums memory sums,
        LPVault vault,
        uint256 positionId,
        int24 lo,
        int24 hi,
        bool falling,
        uint32 spreadBps
    ) internal view {
        (address owner, int24 tickLower, int24 tickUpper,, uint128 liquidity,) = vault.positions(positionId);
        if (owner == address(0) || liquidity == 0) return;
        if (tickLower > lo) lo = tickLower;
        if (tickUpper < hi) hi = tickUpper;
        for (int24 t = lo; t < hi; t++) {
            _sumLevel(sums, t, liquidity, falling, spreadBps);
        }
    }

    /// @dev Adds one level's tokens, bid spend, and model spend, in liquidity units, to `sums`.
    function _sumLevel(FillSums memory sums, int24 t, uint128 liquidity, bool falling, uint32 spreadBps) internal pure {
        // t lies inside [0, 10000) because every range does (FEAT-T7AF FR-T7B2)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 level = uint256(int256(t));
        (uint256 bidYes, uint256 bidNo) = _boardBids(level, spreadBps);
        sums.tokensScaled += liquidity;
        sums.bidScaled += uint256(liquidity) * (falling ? bidYes : bidNo);
        sums.modelScaled += uint256(liquidity) * (falling ? level : BPS - level);
    }

    /// @dev The house board's two bids at level `t`, in bps, for the spread `spreadBps`
    ///      (quotes.Board): the spread splits by the worst-case loss per share, bearMargin =
    ///      spread x t / 10000 on the YES bid and the rest on the NO bid; a margin that would take
    ///      a bid below the 100 bps floor is capped there and the blocked part moves to the other
    ///      bid, so the two bids still sum to 10000 minus the spread. Reverts outside the band
    ///      [100, 9900], where the board quotes no level.
    function _boardBids(uint256 t, uint256 spreadBps) internal pure returns (uint256 bidYes, uint256 bidNo) {
        require(t >= BOARD_FLOOR_BPS && t <= BOARD_CEILING_BPS, "KeeperFillFixture: level outside the board's band");
        uint256 probNo = BPS - t;
        uint256 bearMargin = spreadBps * t / BPS;
        uint256 bullMargin = spreadBps - bearMargin;
        uint256 maxBull = probNo - BOARD_FLOOR_BPS;
        if (bullMargin > maxBull) {
            bullMargin = maxBull;
            bearMargin = spreadBps - maxBull;
        }
        uint256 maxBear = t - BOARD_FLOOR_BPS;
        if (bearMargin > maxBear) {
            bearMargin = maxBear;
            bullMargin = spreadBps - maxBear;
        }
        bidYes = t - bearMargin;
        bidNo = probNo - bullMargin;
    }
}
