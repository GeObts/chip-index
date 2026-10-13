// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Timelock} from "./Timelock.sol";

/**
 * @notice One rule for every owner setting in Chip Index:
 *
 *         - A change that only STOPS or RESTRICTS something (a lower cap, a tighter limit, a
 *           shorter feed age, removing a keeper) is instant: `tighten(key, value)`.
 *         - Anything else (raising a cap or a fee, adding a keeper, choosing a pool) goes through
 *           the 48h timelock: `queueSetting(key, value)`, wait, `executeSetting(key, value)`.
 *
 *         Each contract numbers its own settings (`key`) and says what "tighter" means for each;
 *         the default is "a lower number". Bounds are checked on tighten, on queue and again on
 *         execute. A setting that can never be tightened (a pool choice) only goes through the
 *         timelock.
 */
abstract contract Settings is Ownable2Step, Timelock {
    bytes32 public constant ACTION_SETTING = keccak256("SETTING");

    event SettingChanged(uint8 indexed key, uint256 oldValue, uint256 newValue);

    error NotATightening(uint8 key, uint256 value);
    error UnknownSetting(uint8 key);

    /// @notice Instant change that only restricts (see the contract's setting list).
    function tighten(uint8 key, uint256 value) external onlyOwner {
        _checkSetting(key, value);
        if (!_isTightening(key, value)) revert NotATightening(key, value);
        _set(key, value);
    }

    /// @notice Queue any change to a setting (48h timelock, 14-day grace).
    function queueSetting(uint8 key, uint256 value) external onlyOwner returns (bytes32) {
        _checkSetting(key, value);
        return _queue(ACTION_SETTING, abi.encode(key, value));
    }

    function executeSetting(uint8 key, uint256 value) external onlyOwner {
        _consume(ACTION_SETTING, abi.encode(key, value));
        _checkSetting(key, value);
        _set(key, value);
    }

    /// @notice Cancel any queued change on this contract.
    function cancelChange(bytes32 id) external onlyOwner {
        _cancel(id);
    }

    /// @notice Current value of a setting, as a number (addresses and tick spacings included).
    function setting(uint8 key) external view returns (uint256) {
        return _getSetting(key);
    }

    function _set(uint8 key, uint256 value) internal {
        uint256 old = _getSetting(key);
        _applySetting(key, value);
        emit SettingChanged(key, old, value);
    }

    /// @dev Default: a lower number is tighter. Override for keepers (only 0) and pools (never).
    function _isTightening(uint8 key, uint256 value) internal view virtual returns (bool) {
        return value <= _getSetting(key);
    }

    /// @dev Reverts UnknownSetting for an unknown key, or the contract's own error when out of bounds.
    function _checkSetting(uint8 key, uint256 value) internal view virtual;

    function _getSetting(uint8 key) internal view virtual returns (uint256);

    function _applySetting(uint8 key, uint256 value) internal virtual;
}
