// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { HeirVault } from "../src/HeirVault.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract HeirVaultTest is Test {
    event Heartbeat(address indexed owner, uint256 timestamp);
    event Released(address indexed heir, uint256 ethAmount);

    uint256 constant PERIOD = 90 days;

    HeirVault vault;
    address proxy = makeAddr("callbackProxy");
    address reactive = makeAddr("reactiveContract");
    address heir = makeAddr("heir");

    receive() external payable {}

    function setUp() public {
        vm.warp(1_000_000);
        vault = new HeirVault{ value: 1 ether }(IPayable(payable(proxy)), reactive, heir, PERIOD);
    }

    function _release() internal {
        vm.prank(proxy);
        vault.release(reactive);
    }

    function test_ConstructorRecordsHeartbeat() public view {
        assertEq(vault.owner(), address(this));
        assertEq(vault.heir(), heir);
        assertEq(vault.lastHeartbeat(), 1_000_000);
        assertFalse(vault.isExpired());
    }

    function test_ReleaseRevertsWhileOwnerActive() public {
        vm.warp(1_000_000 + PERIOD);
        vm.prank(proxy);
        vm.expectRevert(HeirVault.StillActive.selector);
        vault.release(reactive);
    }

    function test_ReleasePaysHeirAfterInactivity() public {
        vm.warp(1_000_000 + PERIOD + 1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Released(heir, 1 ether - vault.CALLBACK_RESERVE());
        _release();
        assertEq(heir.balance, 1 ether - vault.CALLBACK_RESERVE());
        assertEq(address(vault).balance, vault.CALLBACK_RESERVE());
        assertTrue(vault.released());
    }

    function test_ReleaseAlsoSendsTrackedTokens() public {
        MockToken token = new MockToken();
        token.mint(address(vault), 500e18);
        vault.trackToken(address(token));
        vm.warp(block.timestamp + PERIOD + 1);
        _release();
        assertEq(token.balanceOf(heir), 500e18);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_CannotReleaseTwice() public {
        vm.warp(1_000_000 + PERIOD + 1);
        _release();
        vm.prank(proxy);
        vm.expectRevert(HeirVault.AlreadyReleased.selector);
        vault.release(reactive);
    }

    function test_OnlyCallbackProxyCanRelease() public {
        vm.warp(1_000_000 + PERIOD + 1);
        vm.prank(heir);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, heir, proxy));
        vault.release(reactive);
    }

    function test_WrongReactiveSenderRejected() public {
        vm.warp(1_000_000 + PERIOD + 1);
        address impostor = makeAddr("impostor");
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, impostor, reactive));
        vault.release(impostor);
    }

    function test_PingResetsTimerAndEmitsHeartbeat() public {
        vm.warp(1_000_000 + PERIOD - 10);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Heartbeat(address(this), 1_000_000 + PERIOD - 10);
        vault.ping();
        vm.warp(1_000_000 + PERIOD + 20);
        vm.prank(proxy);
        vm.expectRevert(HeirVault.StillActive.selector);
        vault.release(reactive);
    }

    function test_OnlyOwnerCanPingOrChangeHeir() public {
        vm.startPrank(heir);
        vm.expectRevert(HeirVault.NotOwner.selector);
        vault.ping();
        vm.expectRevert(HeirVault.NotOwner.selector);
        vault.setHeir(heir);
        vm.stopPrank();
    }

    function test_OwnerCanWithdrawAndChangeHeir() public {
        address newHeir = makeAddr("newHeir");
        vault.setHeir(newHeir);
        vault.withdraw(0.4 ether);
        assertEq(address(vault).balance, 0.6 ether);
        vm.warp(block.timestamp + PERIOD + 1);
        _release();
        assertEq(newHeir.balance, 0.6 ether - vault.CALLBACK_RESERVE());
    }

    function test_CannotWithdrawAfterRelease() public {
        vm.warp(1_000_000 + PERIOD + 1);
        _release();
        vm.expectRevert(HeirVault.AlreadyReleased.selector);
        vault.withdraw(1);
    }

    function testFuzz_NeverReleasesEarly(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, PERIOD);
        vm.warp(1_000_000 + elapsed);
        vm.prank(proxy);
        vm.expectRevert(HeirVault.StillActive.selector);
        vault.release(reactive);
    }
}
