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
app/index.html                 no-code web app (create, monitor and ping a vault)
app/contracts.js               ABIs + bytecode exported from forge build
```

## Build and test

```bash
git clone --recurse-submodules <this repo>
cd reactive-heir-vault
forge build
forge test
```

The result is 23/23 tests passing, including fuzz tests. Details are in [test/TESTS.md](test/TESTS.md).

## Web app: no code needed

[`app/index.html`](app/index.html) is a single static page that works with any browser wallet (MetaMask, Rabby, Phantom), so you can use Heir Vault without writing code:

- **Create a vault** in one flow. The app predicts the watcher's address on Lasna, deploys the vault on Sepolia with your deposit, tops up lREACT through Reactive's faucet if needed, deploys the watcher on Lasna, and sends the first heartbeat. Your wallet signs each step, and the page never sees your keys.
- **My vault** shows a live countdown to release, the balance, heir and owner, and whether the watcher on Reactive has seen your latest heartbeat. It also shows how many release requests it has made and how much lREACT it has left. Anyone can look up a vault by address; the owner gets **I'm alive (ping)**, deposit, withdraw and change-heir buttons.
- Deep link: `index.html?vault=0x…`.

Run it locally with any static server from the `app/` folder.

**Tested end to end through the app.** It used a private-key-backed EIP-1193 provider in place of a browser extension, a 2-minute period and Cron100:

| Step | Chain | Transaction |
|---|---|---|
| Vault deployed from the app ([0x0955…2012](https://sepolia.etherscan.io/address/0x095586Aee1011B6537E79E4846Ff0B689ca62012)) | Sepolia | [0x7b02…f2de](https://sepolia.etherscan.io/tx/0x7b0274413039e52e99aebf90d936c60394248993f713b1df0109ec834f31f2de) |
| lREACT top-up through the faucet | Sepolia | [0xddaa…0268](https://sepolia.etherscan.io/tx/0xddaa5850542933dc4d45863bb30c4dfcb82b0f21d248dcb8920e84fb1fa90268) |
| Watcher deployed ([0x0955…2012](https://lasna.reactscan.net/address/0x095586Aee1011B6537E79E4846Ff0B689ca62012)) | Lasna | [0x72ab…d3c4](https://lasna.reactscan.net/tx/0x72aba740035876193f6e8590335420fbe8d46f71a30b8defca1314d6f784d3c4) |
| First heartbeat | Sepolia | [0x254c…7d45](https://sepolia.etherscan.io/tx/0x254ca32b181423bdd80b1b54c6f7f5ce1ae750f0887d8c72a27d669c41cd7d45) |
| CRON check: `ReleaseRequested` | Lasna | [0x83e6…37bd](https://lasna.reactscan.net/tx/0x83e669621c5bb635bb3b9770efbb23f676887d0578ba9f1ed14676e6e02a37bd) |
| `release()`: the heir is paid | Sepolia | [0x09c0…6792](https://sepolia.etherscan.io/tx/0x09c0e4029dbaef0a635abd6813913a4b0c2c81ee46c43165b7153cdfbdd76792) |
| Watcher unsubscribes: `Finished` | Lasna | [0xa6a3…afd9](https://lasna.reactscan.net/tx/0xa6a3f0b442b17eddb23ba46e4a1178bf3ef93e4d5ad2638a4d32adf958dcafd9) |

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
- [x] Demo video under 3 minutes: [`video/heir-vault-demo.mp4`](video/heir-vault-demo.mp4) (1:50), rendered from [`video/demo.html`](video/demo.html).
- [ ] Publish the public GitHub repository and submit on DoraHacks (with the user's approval).
