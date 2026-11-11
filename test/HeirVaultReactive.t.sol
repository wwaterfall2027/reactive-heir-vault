// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { HeirVaultReactive } from "../src/HeirVaultReactive.sol";

/// @dev Records what the reactive contract asks Reactive Network's system contract to do.
contract MockSystem is ISystemContract {
    struct Sub { uint256 chainId; address src; uint256 topic0; }

    Sub[] public subs;
    Sub[] public unsubs;
    CallbackConfiguration_V_1_0[] internal callbacks;

    receive() external payable {}

    function debt(address) external pure returns (uint256) { return 0; }

    function subscribe(uint256 c, address a, uint256 t0, uint256, uint256, uint256) external {
        subs.push(Sub(c, a, t0));
    }

    function unsubscribe(uint256 c, address a, uint256 t0, uint256, uint256, uint256) external {
        unsubs.push(Sub(c, a, t0));
    }

    function requestCallback(CallbackVersion, bytes memory) external pure { revert("unused"); }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        callbacks.push(config_);
    }

    function subsCount() external view returns (uint256) { return subs.length; }
    function unsubsCount() external view returns (uint256) { return unsubs.length; }
    function callbacksCount() external view returns (uint256) { return callbacks.length; }
    function callbackAt(uint256 i) external view returns (CallbackConfiguration_V_1_0 memory) { return callbacks[i]; }
}

contract HeirVaultReactiveTest is Test {
    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 constant DEST = 11155111;
    uint256 constant PERIOD = 600;

    MockSystem sys;
    HeirVaultReactive rc;
    address vault = makeAddr("vault");

    function setUp() public {
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM_ADDR));
        vm.warp(10_000);
        rc = new HeirVaultReactive(DEST, vault, PERIOD, CRON100);
    }

    function _log(uint256 chainId, address src, uint256 topic0, bytes memory data)
        internal pure returns (IReactive.LogRecord memory r)
    {
        r.chainId = chainId;
        r.contractAddress = src;
        r.topic0 = topic0;
        r.data = data;
    }

    // Build the log first: vm.prank applies to the very next external call.
    function _heartbeat(uint256 ts) internal {
        IReactive.LogRecord memory l = _log(DEST, vault, rc.HEARTBEAT_TOPIC_0(), abi.encode(ts));
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
    }

    function _cron() internal {
        IReactive.LogRecord memory l = _log(block.chainid, LEGACY_SYSTEM_ADDR, CRON100, abi.encode(block.number));
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
    }

    function _released() internal {
        IReactive.LogRecord memory l = _log(DEST, vault, rc.RELEASED_TOPIC_0(), abi.encode(uint256(1 ether)));
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
    }

    function test_SubscribesToVaultEventsAndLegacyCron() public view {
        assertEq(sys.subsCount(), 3);
        (uint256 c0, address a0, uint256 t0) = sys.subs(0);
        (uint256 c1, address a1, uint256 t1) = sys.subs(1);
        (uint256 c2, address a2, uint256 t2) = sys.subs(2);
        assertEq(c0, DEST); assertEq(a0, vault); assertEq(t0, rc.HEARTBEAT_TOPIC_0());
        assertEq(c1, DEST); assertEq(a1, vault); assertEq(t1, rc.RELEASED_TOPIC_0());
        assertEq(c2, block.chainid); assertEq(a2, LEGACY_SYSTEM_ADDR); assertEq(t2, CRON100);
    }

    function test_OnlySystemCanReact() public {
        IReactive.LogRecord memory l = _log(DEST, vault, rc.HEARTBEAT_TOPIC_0(), abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        rc.react(l);
    }

    function test_HeartbeatIsRecorded() public {
        _heartbeat(10_000);
        assertEq(rc.lastHeartbeat(), 10_000);
    }

    function test_HeartbeatFromOtherContractOrChainIgnored() public {
        uint256 topic = rc.HEARTBEAT_TOPIC_0();
        vm.startPrank(SYSTEM_ADDR);
        rc.react(_log(DEST, makeAddr("other"), topic, abi.encode(uint256(5))));
        rc.react(_log(1, vault, topic, abi.encode(uint256(5))));
        vm.stopPrank();
        assertEq(rc.lastHeartbeat(), 0);
    }

    function test_NoRequestBeforeAnyHeartbeat() public {
        vm.warp(10_000 + 10 * PERIOD);
        _cron();
        assertEq(sys.callbacksCount(), 0);
    }

    function test_NoRequestWhileOwnerActive() public {
        _heartbeat(10_000);
        vm.warp(10_000 + PERIOD);
        _cron();
        assertEq(sys.callbacksCount(), 0);
    }

    function test_RequestsReleaseAfterInactivity() public {
        _heartbeat(10_000);
        vm.warp(10_000 + PERIOD + 1);
        _cron();
        assertEq(sys.callbacksCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.callbackAt(0);
        assertEq(cb.chainId, DEST);
        assertEq(cb.recipient, vault);
        assertEq(cb.gasLimit, rc.CALLBACK_GAS_LIMIT());
        assertEq(cb.payload, abi.encodeWithSignature("release(address)", address(0)));
        assertEq(rc.requests(), 1);
    }

    function test_RetriesOnlyAfterDelay() public {
        _heartbeat(10_000);
        vm.warp(10_000 + PERIOD + 1);
        _cron();
        uint256 delay = rc.RETRY_DELAY();
        vm.warp(block.timestamp + delay);
        _cron();
        assertEq(sys.callbacksCount(), 1, "no retry before delay");
        vm.warp(block.timestamp + 1);
        _cron();
        assertEq(sys.callbacksCount(), 2, "retry after delay");
    }

    function test_HeartbeatAfterRequestCancelsIt() public {
        _heartbeat(10_000);
        vm.warp(10_000 + PERIOD + 1);
        _cron();
        _heartbeat(block.timestamp);
        assertEq(rc.lastRequestAt(), 0);
        vm.warp(block.timestamp + rc.RETRY_DELAY() + 1);
        _cron();
        assertEq(sys.callbacksCount(), 1);
    }

    function test_ReleasedUnsubscribesAndStops() public {
        _heartbeat(10_000);
        vm.warp(10_000 + PERIOD + 1);
        _cron();
        _released();
        assertTrue(rc.done());
        assertEq(sys.unsubsCount(), 3);
        (, address a2, uint256 t2) = sys.unsubs(2);
        assertEq(a2, LEGACY_SYSTEM_ADDR);
        assertEq(t2, CRON100);
        vm.warp(block.timestamp + 1 days);
        _cron();
        _heartbeat(block.timestamp);
        assertEq(sys.callbacksCount(), 1);
        assertEq(rc.lastHeartbeat(), 10_000);
    }

    function testFuzz_ShouldRequestMatchesRule(uint256 silence) public {
        silence = bound(silence, 0, 10 * PERIOD);
        _heartbeat(10_000);
        assertEq(rc.shouldRequest(10_000 + silence), silence > PERIOD);
    }
}
