import {
	bytesToHex,
	cre,
	encodeCallMsg,
	getNetwork,
	LAST_FINALIZED_BLOCK_NUMBER,
	prepareReportRequest,
	TxStatus,
	type Runtime,
} from '@chainlink/cre-sdk'
import {
	decodeFunctionResult,
	encodeAbiParameters,
	encodeFunctionData,
	parseAbi,
	parseAbiParameters,
	zeroAddress,
	type Address,
} from 'viem'
import { z } from 'zod'

// LuckYou 彩票 keeper（SPEC Q8）：
// cron 轮询 -> 链下调用 checkUpkeep -> 需要开奖时经 DON 签名报告
// 投递到 LotteryKeeperReceiver -> 转调 performUpkeep

const lotteryAbi = parseAbi([
	'function checkUpkeep(bytes data) view returns (bool upkeepNeeded, bytes performData)',
])

// ─── Config Schema ──────────────────────────────────────────
export const configSchema = z.object({
	schedule: z.string(),
	evms: z.array(
		z.object({
			chainSelectorName: z.string(),
			lotteryAddress: z.string(),
			receiverAddress: z.string(),
		}),
	),
})
type Config = z.infer<typeof configSchema>

// ─── Callback ───────────────────────────────────────────────
export const onCronTrigger = (runtime: Runtime<Config>): string => {
	const evmConfig = runtime.config.evms[0]

	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: evmConfig.chainSelectorName,
		isTestnet: true,
	})
	if (!network) throw new Error(`Network not found: ${evmConfig.chainSelectorName}`)

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// 1. 链下读取：当前期是否到达开奖时刻
	const callData = encodeFunctionData({
		abi: lotteryAbi,
		functionName: 'checkUpkeep',
		args: ['0x'],
	})
	const readResult = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: evmConfig.lotteryAddress as Address,
				data: callData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	const [upkeepNeeded] = decodeFunctionResult({
		abi: lotteryAbi,
		functionName: 'checkUpkeep',
		data: bytesToHex(readResult.data),
	}) as readonly [boolean, `0x${string}`]

	runtime.log(`checkUpkeep(${evmConfig.lotteryAddress}) => ${upkeepNeeded}`)

	if (!upkeepNeeded) {
		return 'Skipped — draw not due'
	}

	// 2. 需要开奖：DON 签名报告投递给桥接接收器
	const reportData = encodeAbiParameters(parseAbiParameters('bool shouldExecute'), [true])
	const reportResponse = runtime.report(prepareReportRequest(reportData)).result()

	const writeResult = evmClient
		.writeReport(runtime, {
			receiver: evmConfig.receiverAddress as Address,
			report: reportResponse,
			gasConfig: { gasLimit: '2000000' },
		})
		.result()

	if (writeResult.txStatus !== TxStatus.SUCCESS) {
		throw new Error(`Keeper TX failed: ${writeResult.errorMessage || writeResult.txStatus}`)
	}
	if (
		writeResult.receiverContractExecutionStatus !== undefined &&
		writeResult.receiverContractExecutionStatus !== 0
	) {
		throw new Error(
			`Receiver execution failed: status ${writeResult.receiverContractExecutionStatus}`,
		)
	}

	const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32))
	runtime.log(`Draw triggered! TX: ${txHash}`)
	return `Executed — tx: ${txHash}`
}

// ─── Workflow Init ──────────────────────────────────────────
export function initWorkflow(config: Config) {
	const cronTrigger = new cre.capabilities.CronCapability()

	return [cre.handler(cronTrigger.trigger({ schedule: config.schedule }), onCronTrigger)]
}
