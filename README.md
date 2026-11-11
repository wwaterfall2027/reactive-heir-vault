# Heir Vault: a dead man's switch that runs itself

Reactive Omni Buildathon, track **Set It and Forget It**.

> **Status:** compiles with solc 0.8.34 (no warnings). **23/23 Foundry tests pass**, including fuzz tests and tests of the reactive logic. Deployed on Ethereum Sepolia and Reactive Lasna, where the **full loop (heartbeat, silence, CRON, callback, release, unsubscribe) ran end to end** (see Live deployment).

## The problem

When someone who holds crypto dies or loses access, the funds are usually gone for good. Existing "dead man's switch" tools depend on a server or a keeper bot that someone has to pay for and keep running.

## How it works

1. The owner deposits ETH or ERC-20 tokens into an `HeirVault` on Ethereum Sepolia and names an heir and an inactivity period (for example, 90 days).
2. Every time the owner calls `ping()`, or moves funds through the vault, the vault emits `Heartbeat(owner, timestamp)`.
3. A reactive contract on Reactive Network:
   - subscribes to `Heartbeat` events from the vault and records the last one;
   - subscribes to Reactive's built-in CRON events so it checks on a schedule, with no bot;
   - when `now - lastHeartbeat > inactivityPeriod`, requests a callback to the vault;
   - if the vault has not confirmed `Released` 5 minutes after a request, asks again (a failed callback is not fatal);
   - when it sees the vault's `Released` event, unsubscribes from everything so it stops paying for CRON ticks.
4. The vault's `release()` callback, which only the Reactive callback proxy can call and only on behalf of the authorized reactive contract, sends everything to the heir.

No server, no keeper, no off-chain code. The owner sets it up once and forgets it.

## Safety rules in the vault

- `release()` re-checks the inactivity period on the destination chain using `block.timestamp`, so a wrong callback cannot release funds early.
- The owner can cancel, withdraw or change the heir at any time while active.
- The heir can do nothing before the period expires.

## Layout

```
src/HeirVault.sol              destination contract (Ethereum Sepolia)
src/HeirVaultReactive.sol      reactive contract (Reactive Network)
test/HeirVault.t.sol           vault tests (Foundry)
test/HeirVaultReactive.t.sol   reactive logic tests with a mocked system contract
test/TESTS.md                  what every test checks
script/deploy.js               deployment plan used for the testnet run (ethers v6)
```

## Build and test

```bash
git clone --recurse-submodules <this repo>
cd reactive-heir-vault
forge build
forge test
```

The result is 23/23 tests passing, including fuzz tests. Details are in [test/TESTS.md](test/TESTS.md).

## Live deployment (testnet)

Demo settings: inactivity period **10 minutes**, CRON topic `Cron100` (about every 2 minutes).

| Contract | Chain | Address |
|---|---|---|
| `HeirVault` | Ethereum Sepolia (11155111) | [0x950B…bdA9](https://sepolia.etherscan.io/address/0x950B3901EFE0362ED9eA3488815e774cF062bdA9) |
| `HeirVaultReactive` | Reactive Lasna (5318007) | [0x4067…957b](https://lasna.reactscan.net/address/0x4067F70d1137FB84534462fca3EBC5eA0519957b) |

**The full loop ran end to end with no server, keeper or off-chain code.** Each step:

| Step | Chain | Transaction |
|---|---|---|
| 1. Deploy vault with 0.01 ETH; heir set; inactivity period 600 s | Sepolia | [0x05cd…6956](https://sepolia.etherscan.io/tx/0x05cdf1e49cb5e85ff2e91bafd1b33b34843ff17d927f0d36501b24c112276956) |
| 2. Deploy reactive contract; subscribes to the vault's `Heartbeat` and `Released`, and to `Cron100` | Lasna | [0x5a7b…2a56](https://lasna.reactscan.net/tx/0x5a7b9b82216ac7128017fef57fd35b08daee2d5c44ec4fee8b56d60058882a56) |
| 3. Owner `ping()`; the reactive contract recorded `lastHeartbeat = 1794429096` | Sepolia, then Lasna | [0x6876…2bde](https://sepolia.etherscan.io/tx/0x6876db234de416f88b8486bc443f992a3638c877cc0a577f4d597965e4a02bde) |
| 4. Silence for more than 10 minutes; a CRON tick emits `ReleaseRequested` (attempt 1) and requests the callback | Lasna | [0x89ff…9adb](https://lasna.reactscan.net/tx/0x89fff29f83da72d773839b3e81b2783a4b82a4cf2f1b675b18c542bfc40a9adb) |
| 5. Callback runs `release()`; heir receives **0.0095 ETH** and the vault keeps a 0.0005 ETH reserve for callback fees | Sepolia | [0xe31b…ffe9](https://sepolia.etherscan.io/tx/0xe31bc044287f2deb94ebed2bb599b45129583ab4a3ca4b17a1100e5a60d4ffe9) |
| 6. The reactive contract sees `Released`, unsubscribes from everything and emits `Finished`, so it stops paying for ticks | Lasna | [0xb963…47eb](https://lasna.reactscan.net/tx/0xb9638d10b2f2ed85d27754da9d17f2a271fa4962016e83f0c879178d06b647eb) |

Independently checked with `cast`: `vault.released() == true`, heir balance 0.0095 ETH, `reactive.done() == true`, `reactive.requests() == 1`.

Deployer funding: Sepolia ETH from the PoW faucet; lREACT from Reactive's faucet ([0xf6d2…9929](https://sepolia.etherscan.io/tx/0xf6d288fc37df0b81acb749fa08d65f7f7217b8581096ce55378745ef2f099929)).

### What the earlier deployments taught us

Two earlier versions failed on testnet, and each failure made the design better:

1. **CRON from the wrong address.** The first version ([vault](https://sepolia.etherscan.io/address/0xFbe4946E3Cf2aAccF6a88449c825f3A5E3a3AeB6), [reactive](https://lasna.reactscan.net/address/0xFbe4946E3Cf2aAccF6a88449c825f3A5E3a3AeB6)) received heartbeats but never got CRON ticks. It had subscribed on the Omni system contract (`0x8888…8888`), but Cron events come from the **legacy system contract `0x…fffFfF`**.
2. **A failed callback must not be final.** The second version ([vault](https://sepolia.etherscan.io/address/0x9157310D22E80a51b261473e1D9e51fAF5a5361C), [reactive](https://lasna.reactscan.net/address/0x2B9705c7c4D065b73Ba27bcdcacac7cF2de97Bd9)) requested the release correctly, but the callback ended in [`CallbackFailure`](https://sepolia.etherscan.io/tx/0x140939f27e8cb82fd3343aff792115c8d1b2ea51e31a8ee17eb09b7eb623de9c). Replaying it with `cast run` showed `release()` running out of gas while paying a brand-new heir account: creating an account is expensive on current Sepolia, and the proxy withholds part of the requested gas. That version would never have retried. The current version:
   - requests 1,000,000 gas for the callback;
   - re-requests the release every 5 minutes until the vault confirms `Released`;
   - unsubscribes once it is done, because CRON is billed on every tick.

## To do before submitting

- [x] Compile against `reactive-lib-omni` (solc 0.8.34, in-browser).
- [x] Pass all tests (23/23 with Foundry, including fuzz and reactive-logic tests).
- [x] Confirm the CRON topics (Cron1 … Cron10000, from Reactive's CRON demo).
- [x] Throwaway testnet deployer: `0xAC094DfE7FF9f40DB91533d3e050e60026388848` (key stays in the browser, never shared).
- [x] Fund the deployer with Sepolia ETH (PoW faucet).
- [x] Deploy to Ethereum Sepolia and Reactive Lasna.
- [x] Cross-chain heartbeat verified (Sepolia `Heartbeat` to Lasna `react()`).
- [x] Verify automatic release after inactivity (CRON, callback, release, unsubscribe).
- [ ] Demo video under 3 minutes.
- [ ] Publish the public GitHub repository and submit on DoraHacks (with the user's approval).
