// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title HeirVaultReactive
/// @notice Watches an HeirVault's Heartbeat events and Reactive's CRON ticks.
///         When the owner has been silent longer than the inactivity period,
///         it asks the vault to release funds to the heir, retrying if a callback
///         fails. Once the vault reports `Released`, it unsubscribes from everything
///         so it stops paying for ticks.
contract HeirVaultReactive is IReactive, AbstractReactive {
    /// @notice Legacy system contract that emits the Cron events.
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    uint256 public constant HEARTBEAT_TOPIC_0 = uint256(keccak256("Heartbeat(address,uint256)"));
    uint256 public constant RELEASED_TOPIC_0 = uint256(keccak256("Released(address,uint256)"));

    /// @notice Gas requested for the callback. The proxy keeps part of it for its own
    ///         accounting, and paying a brand-new heir account is expensive, so leave headroom.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice If the vault has not confirmed `Released` this long after a request, ask again.
    uint256 public constant RETRY_DELAY = 5 minutes;

    uint256 public immutable destinationChainId;
    address public immutable vault;
    uint256 public immutable inactivityPeriod;
    uint256 public immutable cronTopic;

    uint256 public lastHeartbeat;
    uint256 public lastRequestAt;
    uint256 public requests;
    bool public done;

    event ReleaseRequested(uint256 lastHeartbeat, uint256 checkedAt, uint256 attempt);
    event Finished();

    constructor(
        uint256 destinationChainId_,
        address vault_,
        uint256 inactivityPeriod_,
        uint256 cronTopic_
    ) payable {
        destinationChainId = destinationChainId_;
        vault = vault_;
        inactivityPeriod = inactivityPeriod_;
        cronTopic = cronTopic_;
        _setSubscriptions(true);
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log) external onlySystem {
        if (done) return;

        if (log.contractAddress == vault && log.chainId == destinationChainId) {
            if (log.topic0 == HEARTBEAT_TOPIC_0) {
                (uint256 ts) = abi.decode(log.data, (uint256));
                if (ts > lastHeartbeat) lastHeartbeat = ts;
                lastRequestAt = 0;
            } else if (log.topic0 == RELEASED_TOPIC_0) {
                done = true;
                _setSubscriptions(false);
                emit Finished();
            }
            return;
        }

        if (log.topic0 == cronTopic && shouldRequest(block.timestamp)) {
            lastRequestAt = block.timestamp;
            requests += 1;
            emit ReleaseRequested(lastHeartbeat, block.timestamp, requests);
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: destinationChainId,
                    recipient: vault,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: abi.encodeWithSignature("release(address)", address(0))
                })
            );
        }
    }

    /// @notice True when a CRON tick at `now_` should (re)request the release callback.
    function shouldRequest(uint256 now_) public view returns (bool) {
        if (done || lastHeartbeat == 0) return false;
        if (now_ <= lastHeartbeat + inactivityPeriod) return false;
        return lastRequestAt == 0 || now_ > lastRequestAt + RETRY_DELAY;
    }

    function _setSubscriptions(bool on) internal {
        uint256[3] memory topics = [HEARTBEAT_TOPIC_0, RELEASED_TOPIC_0, cronTopic];
        for (uint256 i = 0; i < 3; i++) {
            uint256 chain = i < 2 ? destinationChainId : block.chainid;
            address src = i < 2 ? vault : LEGACY_SYSTEM_ADDR;
            if (on) {
                SYSTEM.subscribe(chain, src, topics[i], REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            } else {
                SYSTEM.unsubscribe(chain, src, topics[i], REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            }
        }
    }
}
