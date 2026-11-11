// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @title HeirVault
/// @notice Holds ETH and tokens for an owner. If the owner stops sending heartbeats
///         for `inactivityPeriod`, a Reactive Network callback releases everything to the heir.
contract HeirVault is AbstractCallback {
    /// @notice ETH kept back on release so the vault can still pay the callback proxy.
    uint256 public constant CALLBACK_RESERVE = 0.0005 ether;

    address public immutable owner;
    address public heir;
    uint256 public inactivityPeriod;
    uint256 public lastHeartbeat;
    bool public released;

    address[] public tokens;

    event Heartbeat(address indexed owner, uint256 timestamp);
    event HeirChanged(address indexed heir);
    event Released(address indexed heir, uint256 ethAmount);

    error NotOwner();
    error AlreadyReleased();
    error StillActive();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param callbackProxy_ Reactive callback proxy on this chain.
    /// @param reactiveContract_ The HeirVaultReactive contract allowed to trigger `release`.
    constructor(
        IPayable callbackProxy_,
        address reactiveContract_,
        address heir_,
        uint256 inactivityPeriod_
    ) payable AbstractCallback(callbackProxy_, reactiveContract_) {
        owner = msg.sender;
        heir = heir_;
        inactivityPeriod = inactivityPeriod_;
        _beat();
    }

    /// @notice Owner proves they are still around.
    function ping() external onlyOwner {
        _beat();
    }

    function setHeir(address heir_) external onlyOwner {
        if (released) revert AlreadyReleased();
        heir = heir_;
        emit HeirChanged(heir_);
        _beat();
    }

    function trackToken(address token) external onlyOwner {
        tokens.push(token);
        _beat();
    }

    function withdraw(uint256 amount) external onlyOwner {
        if (released) revert AlreadyReleased();
        _beat();
        (bool ok, ) = owner.call{ value: amount }("");
        require(ok, "eth transfer failed");
    }

    /// @notice True when the owner has been silent longer than the inactivity period.
    function isExpired() public view returns (bool) {
        return _now() > lastHeartbeat + inactivityPeriod;
    }

    /// @notice Called by the Reactive callback proxy. The proxy overwrites the first
    ///         argument with the address of the reactive contract that requested the callback.
    function release(address reactive_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        if (released) revert AlreadyReleased();
        if (!isExpired()) revert StillActive();
        released = true;

        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20Minimal t = IERC20Minimal(tokens[i]);
            uint256 tokenBal = t.balanceOf(address(this));
            if (tokenBal > 0) require(t.transfer(heir, tokenBal), "token transfer failed");
        }

        uint256 bal = address(this).balance;
        uint256 ethAmount = bal > CALLBACK_RESERVE ? bal - CALLBACK_RESERVE : 0;
        emit Released(heir, ethAmount);
        if (ethAmount > 0) {
            (bool ok, ) = heir.call{ value: ethAmount }("");
            require(ok, "eth transfer failed");
        }
    }

    function _beat() internal {
        lastHeartbeat = _now();
        emit Heartbeat(owner, lastHeartbeat);
    }

    /// @dev Overridable clock so tests can simulate the passage of time.
    function _now() internal view virtual returns (uint256) {
        return block.timestamp;
    }
}
