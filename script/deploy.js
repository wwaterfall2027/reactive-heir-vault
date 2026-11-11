// Deployment plan for Heir Vault (testnet only). Runs in a browser page with ethers v6
// and the compiler output from the in-browser solc build.
//
// The two contracts reference each other (the vault trusts the reactive contract,
// and the reactive contract watches the vault), so both addresses are predicted
// from the throwaway deployer's nonces before anything is deployed:
//   Sepolia nonce 0 -> HeirVault
//   Sepolia nonce 1 -> send SepETH to the Reactive faucet (receives lREACT on Lasna)
//   Lasna   nonce 0 -> HeirVaultReactive
//
// Demo settings: inactivityPeriod = 10 minutes and Cron100 (about 2 minutes), so the full
// loop (heartbeat, silence, CRON check, callback, release) can be shown in one session.

export const CONFIG = {
  sepoliaRpc: 'https://ethereum-sepolia-rpc.publicnode.com',
  lasnaRpc: 'https://lasna-rpc.rnk.dev/',
  sepoliaChainId: 11155111n,
  callbackProxySepolia: '0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4',
  reactiveFaucetSepolia: '0x9b9BB25f1A81078C544C829c5EB7822d747Cf434',
  // Cron events come from the legacy system contract 0x...fffFfF (handled in the contract).
  cron100Topic: '0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70',
  lasnaGasPrice: 100000000000n,    // Lasna has no EIP-1559 fee data: send legacy (type 0) txs
  inactivityPeriod: 600n,          // 10 minutes for the demo
  vaultDeposit: '0.01',            // SepETH locked in the vault for the demo
  faucetAmount: '0.1',             // SepETH -> 10 lREACT
  reactiveFunding: '2',            // lREACT sent with the reactive contract to pay for reactions
};

export async function deploy(ethers, artifacts, privateKey, heir) {
  const sep = new ethers.JsonRpcProvider(CONFIG.sepoliaRpc);
  const las = new ethers.JsonRpcProvider(CONFIG.lasnaRpc);
  const wSep = new ethers.Wallet(privateKey, sep);
  const wLas = new ethers.Wallet(privateKey, las);
  const me = wSep.address;

  const nSep = await sep.getTransactionCount(me);
  const nLas = await las.getTransactionCount(me);
  const vaultAddr = ethers.getCreateAddress({ from: me, nonce: nSep });
  const reactiveAddr = ethers.getCreateAddress({ from: me, nonce: nLas });
  const log = { me, vaultAddr, reactiveAddr, txs: {} };

  // 1. Vault on Sepolia (trusts the predicted reactive address).
  const V = artifacts.vault;
  const vault = await new ethers.ContractFactory(V.abi, V.bytecode, wSep).deploy(
    CONFIG.callbackProxySepolia, reactiveAddr, heir, CONFIG.inactivityPeriod,
    { value: ethers.parseEther(CONFIG.vaultDeposit) });
  log.txs.vaultDeploy = vault.deploymentTransaction().hash;
  await vault.waitForDeployment();
  if ((await vault.getAddress()) !== vaultAddr) throw new Error('vault address mismatch');

  // 2. Get lREACT from the faucet (only if the Lasna balance is too low).
  if ((await las.getBalance(me)) < ethers.parseEther(CONFIG.reactiveFunding) + ethers.parseEther('0.5')) {
    const ftx = await wSep.sendTransaction({ to: CONFIG.reactiveFaucetSepolia, value: ethers.parseEther(CONFIG.faucetAmount) });
    log.txs.faucet = ftx.hash;
    await ftx.wait();
    for (let i = 0; i < 60 && (await las.getBalance(me)) === 0n; i++) await new Promise(r => setTimeout(r, 5000));
  }

  // 3. Reactive contract on Lasna (watches the vault and CRON).
  const R = artifacts.reactive;
  const reactive = await new ethers.ContractFactory(R.abi, R.bytecode, wLas).deploy(
    CONFIG.sepoliaChainId, vaultAddr, CONFIG.inactivityPeriod, CONFIG.cron100Topic,
    { value: ethers.parseEther(CONFIG.reactiveFunding), type: 0, gasPrice: CONFIG.lasnaGasPrice, gasLimit: 1200000n, nonce: nLas });
  log.txs.reactiveDeploy = reactive.deploymentTransaction().hash;
  await reactive.waitForDeployment();
  if ((await reactive.getAddress()) !== reactiveAddr) throw new Error('reactive address mismatch');

  // 4. A heartbeat so the reactive contract records lastHeartbeat.
  // Explicit gas limit: right after deployment some RPCs estimate against stale state.
  const ping = await vault.ping({ gasLimit: 120000n });
  log.txs.ping = ping.hash;
  await ping.wait();
  return log;
}
