// 合约地址与 ABI 的唯一出口（FR-W-07），组件不得散落地址
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Abi,
  type Address,
} from "viem";
import deployment from "./deployment.local.json";
import lotteryAbiJson from "./abi/Lottery.json";
import erc20AbiJson from "./abi/MockERC20.json";
import vrfAbiJson from "./abi/VRFCoordinatorV2_5Mock.json";

export const lotteryAbi = lotteryAbiJson as Abi;
export const erc20Abi = erc20AbiJson as Abi;
export const vrfAbi = vrfAbiJson as Abi;

export const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

export const addresses = {
  lottery: deployment.lottery as Address,
  usdc: deployment.usdc as Address,
  vrfCoordinator: deployment.vrfCoordinator as Address,
  treasury: deployment.treasury as Address,
} as const;

export const expectedChainId = deployment.chainId;

export const publicClient = createPublicClient({ chain: anvil, transport: http() });

// anvil 默认解锁账户（公开的测试账户，仅本地使用）
export const ANVIL_ACCOUNTS: { name: string; address: Address }[] = [
  { name: "账户 #0（owner）", address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" },
  { name: "账户 #1", address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" },
  { name: "账户 #2", address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" },
];

export function walletFor(account: Address) {
  return createWalletClient({ chain: anvil, transport: http(), account });
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
