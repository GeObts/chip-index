// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice 48h queue -> execute timelock with a 14-day grace window, the chipworks Anvil pattern
 *         (`CONFIG_GRACE`), generalised so one mapping serves every timelocked setting.
 *
 *         A change is identified by `keccak256(action, data)`. Execute must present the SAME
 *         data that was queued, so nothing can be swapped in between queue and execute.
 *         A queued change that is not executed within the grace window expires and must be
 *         re-queued, so a forgotten queue entry cannot be fired months later.
 *
 *         Every change waiting (queued, not yet executed or cancelled) is listed onchain by
 *         `pendingChanges()`, so anyone can see what is coming without reading event history.
 *         An expired entry stays listed until it is cancelled or re-queued.
 */
abstract contract Timelock {
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant TIMELOCK_GRACE = 14 days;

    /// @notice id => earliest execution time. Zero means not queued.
    mapping(bytes32 id => uint256 executableAt) public executableAt;
    bytes32[] internal _pendingIds;
    mapping(bytes32 id => uint256) internal _pendingIndexPlusOne;

    event ChangeQueued(bytes32 indexed id, bytes32 indexed action, bytes data, uint256 executableAt);
    event ChangeExecuted(bytes32 indexed id, bytes32 indexed action);
    event ChangeCancelled(bytes32 indexed id);

    error AlreadyQueued(bytes32 id);
    error NotQueued(bytes32 id);
    error TimelockNotElapsed(uint256 nowTs, uint256 executableAt);
    error TimelockExpired(uint256 nowTs, uint256 expiredAt);

    /// @notice Every change queued and not yet executed or cancelled, with its earliest execution
    ///         time. Entries past `executableAt + TIMELOCK_GRACE` have expired and cannot execute.
    function pendingChanges() external view returns (bytes32[] memory ids, uint256[] memory at) {
        ids = _pendingIds;
        at = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            at[i] = executableAt[ids[i]];
        }
    }

    function changeId(bytes32 action, bytes memory data) public pure returns (bytes32) {
        return keccak256(abi.encode(action, data));
    }

    function _queue(bytes32 action, bytes memory data) internal returns (bytes32 id) {
        id = changeId(action, data);
        uint256 t = executableAt[id];
        // A live entry blocks a duplicate; an expired one may be re-queued.
        if (t != 0 && block.timestamp <= t + TIMELOCK_GRACE) revert AlreadyQueued(id);
        uint256 at = block.timestamp + TIMELOCK_DELAY;
        executableAt[id] = at;
        if (_pendingIndexPlusOne[id] == 0) {
            _pendingIds.push(id);
            _pendingIndexPlusOne[id] = _pendingIds.length;
        }
        emit ChangeQueued(id, action, data, at);
    }

    function _consume(bytes32 action, bytes memory data) internal {
        bytes32 id = changeId(action, data);
        uint256 t = executableAt[id];
        if (t == 0) revert NotQueued(id);
        if (block.timestamp < t) revert TimelockNotElapsed(block.timestamp, t);
        if (block.timestamp > t + TIMELOCK_GRACE) revert TimelockExpired(block.timestamp, t + TIMELOCK_GRACE);
        delete executableAt[id];
        _unlist(id);
        emit ChangeExecuted(id, action);
    }

    function _cancel(bytes32 id) internal {
        if (executableAt[id] == 0) revert NotQueued(id);
        delete executableAt[id];
        _unlist(id);
        emit ChangeCancelled(id);
    }

    function _unlist(bytes32 id) private {
        uint256 ip1 = _pendingIndexPlusOne[id];
        uint256 last = _pendingIds.length;
        if (ip1 != last) {
            bytes32 moved = _pendingIds[last - 1];
            _pendingIds[ip1 - 1] = moved;
            _pendingIndexPlusOne[moved] = ip1;
        }
        _pendingIds.pop();
        delete _pendingIndexPlusOne[id];
    }
}
