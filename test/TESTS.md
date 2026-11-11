# Tests

```bash
forge test
```

Built with Foundry 1.9.0 and solc 0.8.34 (optimizer on, 200 runs), against `reactive-lib-omni` @ `3ade0dc` and `forge-std` @ `dc647cc`.

**Result: 23/23 passing**, including two fuzz tests with 256 runs each.

## `HeirVault.t.sol` (12 tests)

| Test | Checks |
|---|---|
| `test_ConstructorRecordsHeartbeat` | Owner, heir and initial heartbeat are set; not expired. |
| `test_ReleaseRevertsWhileOwnerActive` | `release` at exactly the deadline reverts with `StillActive`. |
| `test_ReleasePaysHeirAfterInactivity` | After the deadline the heir gets the balance minus the 0.0005 ETH callback reserve, and `Released` is emitted. |
| `test_ReleaseAlsoSendsTrackedTokens` | Tracked ERC-20 balances go to the heir too. |
| `test_CannotReleaseTwice` | A second release reverts with `AlreadyReleased`. |
| `test_OnlyCallbackProxyCanRelease` | Any caller other than the Reactive callback proxy gets `NotAuthorized`. |
| `test_WrongReactiveSenderRejected` | A callback carrying any reactive contract but the authorized one gets `CallbackNotAuthorized`. |
| `test_PingResetsTimerAndEmitsHeartbeat` | `ping()` emits `Heartbeat(owner, ts)` and restarts the clock. |
| `test_OnlyOwnerCanPingOrChangeHeir` | Others get `NotOwner`. |
| `test_OwnerCanWithdrawAndChangeHeir` | Withdraw and heir change work, and release pays the new heir. |
| `test_CannotWithdrawAfterRelease` | Funds are locked once released. |
| `testFuzz_NeverReleasesEarly` | For any time up to the deadline, release always reverts. |

## `HeirVaultReactive.t.sol` (11 tests)

Reactive Network's system contract is replaced with `MockSystem`, put at `0x8888…8888` with `vm.etch`. It records every `subscribe`, `unsubscribe` and `requestCallbackV_1_0`, so the reactive logic can be tested without the network.

| Test | Checks |
|---|---|
| `test_SubscribesToVaultEventsAndLegacyCron` | Subscribes to the vault's `Heartbeat` and `Released` on the destination chain, and to `Cron100` on the **legacy** system contract `0x…fffFfF`. |
| `test_OnlySystemCanReact` | Nobody but the system contract can call `react`. |
| `test_HeartbeatIsRecorded` | The heartbeat timestamp is decoded from the log data. |
| `test_HeartbeatFromOtherContractOrChainIgnored` | Spoofed heartbeats from another contract or chain are ignored. |
| `test_NoRequestBeforeAnyHeartbeat` | Never fires before it has seen a heartbeat. |
| `test_NoRequestWhileOwnerActive` | No callback at exactly the deadline. |
| `test_RequestsReleaseAfterInactivity` | Callback to the right chain and vault, with 1,000,000 gas and payload `release(address(0))`. |
| `test_RetriesOnlyAfterDelay` | No duplicate request within `RETRY_DELAY`; a retry once it has passed. |
| `test_HeartbeatAfterRequestCancelsIt` | An owner who comes back cancels the pending request. |
| `test_ReleasedUnsubscribesAndStops` | On `Released`: `done`, 3 unsubscribes, and later ticks or heartbeats are ignored. |
| `testFuzz_ShouldRequestMatchesRule` | `shouldRequest` is true exactly when silence exceeds the period. |

## End-to-end on testnet

The full loop also ran on Ethereum Sepolia and Reactive Lasna. The transaction hashes are in the README.
