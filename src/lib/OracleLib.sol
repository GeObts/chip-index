// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/**
 * @notice Chainlink reads with the checks the Base docs require: positive answer, an
 *         `updatedAt` that is not in the future and not older than `maxAge`, and (when a
 *         sequencer-uptime feed is configured) a sequencer that is up and past its grace period.
 *
 *         The Coinbase stock feeds update on a 0.5% move or a 24h heartbeat during market hours
 *         and FREEZE nights, weekends, holidays and corporate actions (updatedAt stops moving).
 *         So "fresh" here means "updated within maxAge", never "markets are open".
 */
library OracleLib {
    /// @dev Base's L2 sequencer uptime feed answers 0 when up, 1 when down.
    uint256 internal constant SEQUENCER_GRACE = 1 hours;

    error StalePrice(address feed, uint256 updatedAt, uint256 maxAge);
    error BadPrice(address feed, int256 answer);
    error SequencerDown();
    error SequencerGracePeriod(uint256 upSince);

    /// @return answer the raw positive answer (feed decimals)
    function read(address feed, uint256 maxAge) internal view returns (uint256 answer) {
        (, int256 a,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (a <= 0) revert BadPrice(feed, a);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert StalePrice(feed, updatedAt, maxAge);
        }
        answer = uint256(a);
    }

    /// @notice Non-reverting freshness probe. A feed that reverts counts as stale.
    function isFresh(address feed, uint256 maxAge) internal view returns (bool) {
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 a, uint256, uint256 updatedAt, uint80) {
            return a > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge;
        } catch {
            return false;
        }
    }

    /// @notice Reverts unless the sequencer is up and has been for SEQUENCER_GRACE.
    ///         `seqFeed == address(0)` disables the check (unit tests only; the deploy script sets it).
    function checkSequencer(address seqFeed) internal view {
        if (seqFeed == address(0)) return;
        (, int256 status, uint256 startedAt,,) = IAggregatorV3(seqFeed).latestRoundData();
        if (status != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= SEQUENCER_GRACE) revert SequencerGracePeriod(startedAt);
    }

    function sequencerUp(address seqFeed) internal view returns (bool) {
        if (seqFeed == address(0)) return true;
        try IAggregatorV3(seqFeed).latestRoundData() returns (uint80, int256 status, uint256 startedAt, uint256, uint80) {
            return status == 0 && block.timestamp - startedAt > SEQUENCER_GRACE;
        } catch {
            return false;
        }
    }
}
