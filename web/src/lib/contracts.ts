// 合约地址与 ABI 的唯一出口（FR-W-07），组件不得散落地址。
// NEXT_PUBLIC_NETWORK=local（默认）| base-sepolia
import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  http,
  type Abi,
  type Address,
  type Chain,
  type EIP1193Provider,
} from "viem";
import { baseSepolia } from "viem/chains";
import deploymentLocal from "./deployment.local.json";
import deploymentBaseSepolia from "./deployment.base-sepolia.json";
import lotteryAbiJson from "./abi/Lottery.json";
import erc20AbiJson from "./abi/MockERC20.json";
import vrfAbiJson from "./abi/VRFCoordinatorV2_5Mock.json";

export const lotteryAbi = lotteryAbiJson as Abi;
export const erc20Abi = erc20AbiJson as Abi;
export const vrfAbi = vrfAbiJson as Abi;

const NETWORK = process.env.NEXT_PUBLIC_NETWORK ?? "local";
export const IS_LOCAL = NETWORK === "local";

export const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

export const chain: Chain = IS_LOCAL ? anvil : baseSepolia;

const deployment = IS_LOCAL ? deploymentLocal : deploymentBaseSepolia;

export const addresses = {
  lottery: deployment.lottery as Address,
  usdc: deployment.usdc as Address,
  vrfCoordinator: deployment.vrfCoordinator as Address,
  treasury: deployment.treasury as Address,
} as const;

export const expectedChainId = deployment.chainId;
/** 合约部署块：事件扫描的起点（从 0 扫会在公共测试网上产生数千次请求） */
export const startBlock = BigInt((deployment as { startBlock?: number }).startBlock ?? 0);

const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL ?? chain.rpcUrls.default.http[0];

export const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

// anvil 默认解锁账户（公开的测试账户，仅本地使用）
export const ANVIL_ACCOUNTS: { name: string; address: Address }[] = [
  { name: "账户 #0（owner）", address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" },
  { name: "账户 #1", address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" },
  { name: "账户 #2", address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" },
];

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

/** 本地模式：anvil 解锁账户直接签名 */
export function walletFor(account: Address) {
  return createWalletClient({ chain, transport: http(rpcUrl), account });
}

// ===== EIP-6963 多钱包发现 =====
// 浏览器装多个钱包插件时 window.ethereum 会被抢注，必须用 6963 协议点名 MetaMask

interface Eip6963ProviderDetail {
  info: { uuid: string; name: string; rdns: string };
  provider: EIP1193Provider;
}

let selectedProvider: EIP1193Provider | null = null;
export let selectedWalletName = "";

function discoverProviders(timeoutMs = 400): Promise<Eip6963ProviderDetail[]> {
  return new Promise((resolve) => {
    const found: Eip6963ProviderDetail[] = [];
    const handler = (e: Event) => {
      found.push((e as CustomEvent<Eip6963ProviderDetail>).detail);
    };
    window.addEventListener("eip6963:announceProvider", handler);
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    setTimeout(() => {
      window.removeEventListener("eip6963:announceProvider", handler);
      resolve(found);
    }, timeoutMs);
  });
}

async function getInjectedProvider(): Promise<EIP1193Provider> {
  if (selectedProvider) return selectedProvider;
  const providers = await discoverProviders();
  const metamask = providers.find((p) => p.info.rdns === "io.metamask");
  const picked = metamask ?? providers[0];
  if (picked) {
    selectedProvider = picked.provider;
    selectedWalletName = picked.info.name;
    return picked.provider;
  }
  if (window.ethereum) {
    selectedProvider = window.ethereum;
    selectedWalletName = "window.ethereum";
    return window.ethereum;
  }
  throw new Error("未检测到浏览器钱包（请安装 MetaMask）");
}

/** 测试网模式：连接注入钱包（优先 MetaMask），并确保切到目标链（FR-W-05） */
export async function connectInjected(): Promise<Address> {
  const provider = await getInjectedProvider();
  const accounts = (await provider.request({ method: "eth_requestAccounts" })) as Address[];
  const chainIdHex = (await provider.request({ method: "eth_chainId" })) as string;
  if (parseInt(chainIdHex, 16) !== chain.id) {
    try {
      await provider.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: `0x${chain.id.toString(16)}` }],
      });
    } catch {
      await provider.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: `0x${chain.id.toString(16)}`,
            chainName: chain.name,
            nativeCurrency: chain.nativeCurrency,
            rpcUrls: [rpcUrl],
            blockExplorerUrls: chain.blockExplorers ? [chain.blockExplorers.default.url] : [],
          },
        ],
      });
    }
  }
  return accounts[0];
}

/** 测试网模式：通过已选定的注入钱包签名 */
export function injectedWalletFor(account: Address) {
  const provider = selectedProvider ?? window.ethereum;
  if (!provider) {
    throw new Error("未检测到浏览器钱包，请先点击连接");
  }
  return createWalletClient({ chain, transport: custom(provider), account });
}

/** anvil 时间控制（仅本地测试台使用） */
export async function advanceTime(seconds: number) {
  await publicClient.request({
    // anvil 自定义 RPC，viem 类型未覆盖
    method: "evm_increaseTime" as never,
    params: [seconds] as never,
  });
  await publicClient.request({ method: "evm_mine" as never, params: [] as never });
}
