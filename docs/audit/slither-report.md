Multiple frameworks detected: Foundry, solc, Solc-json. Using Foundry (highest priority). Use --compile-force-framework to override.
'forge clean' running (wd: C:\test\LuckYou_2\contracts)
'forge config --json' running
'forge build --build-info --deny never src\Lottery.sol' running (wd: C:\test\LuckYou_2\contracts)
INFO:Detectors:
Detector: divide-before-multiply
Lottery.fulfillRandomWords(uint256,uint256[]) (src/Lottery.sol#298-343) performs a multiplication on the result of a division:
	- perWinner = amount / winners (src/Lottery.sol#327)
	- carryOut += amount - perWinner * winners (src/Lottery.sol#329)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#divide-before-multiply
INFO:Detectors:
Detector: reentrancy-no-eth
Reentrancy in Lottery.performUpkeep(bytes) (src/Lottery.sol#251-281):
	External calls:
	- requestId = _requestRandomWords() (src/Lottery.sol#275)
		- s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))})) (src/Lottery.sol#572-583)
	State variables written after the call(s):
	- _openNextRound(0,0) (src/Lottery.sol#280)
		- newId = ++ s_currentRound (src/Lottery.sol#562)
	Lottery.s_currentRound (src/Lottery.sol#125) can be used in cross function reentrancies:
	- Lottery._openNextRound(uint256,uint256) (src/Lottery.sol#551-569)
	- Lottery.buyTickets(uint32) (src/Lottery.sol#201-224)
	- Lottery.checkUpkeep(bytes) (src/Lottery.sol#239-248)
	- Lottery.fulfillRandomWords(uint256,uint256[]) (src/Lottery.sol#298-343)
	- Lottery.performUpkeep(bytes) (src/Lottery.sol#251-281)
	- Lottery.rolloverExpired(uint32) (src/Lottery.sol#373-399)
	- Lottery.s_currentRound (src/Lottery.sol#125)
	- r.vrfRequestId = requestId (src/Lottery.sol#276)
	Lottery.s_rounds (src/Lottery.sol#126) can be used in cross function reentrancies:
	- Lottery._deriveWinners(uint32) (src/Lottery.sol#621-647)
	- Lottery._openNextRound(uint256,uint256) (src/Lottery.sol#551-569)
	- Lottery.buyTickets(uint32) (src/Lottery.sol#201-224)
	- Lottery.checkUpkeep(bytes) (src/Lottery.sol#239-248)
	- Lottery.fulfillRandomWords(uint256,uint256[]) (src/Lottery.sol#298-343)
	- Lottery.getRound(uint32) (src/Lottery.sol#442-469)
	- Lottery.injectPot(uint32,uint256) (src/Lottery.sol#227-234)
	- Lottery.ownerOfTicket(uint32,uint32) (src/Lottery.sol#436-439)
	- Lottery.pendingPrizes(uint32,address) (src/Lottery.sol#506-531)
	- Lottery.performUpkeep(bytes) (src/Lottery.sol#251-281)
	- Lottery.retryDraw(uint32) (src/Lottery.sol#284-294)
	- Lottery.rolloverExpired(uint32) (src/Lottery.sol#373-399)
	- Lottery.vrfRequestOf(uint32) (src/Lottery.sol#481-488)
	- Lottery.winnersOf(uint32) (src/Lottery.sol#496-503)
	- _openNextRound(0,0) (src/Lottery.sol#280)
		- r.state = RoundState.OPEN (src/Lottery.sol#564)
		- r.closeTime = t (src/Lottery.sol#565)
		- r.pot = carryPot (src/Lottery.sol#566)
		- r.tier1Carry = carryTier1 (src/Lottery.sol#567)
	Lottery.s_rounds (src/Lottery.sol#126) can be used in cross function reentrancies:
	- Lottery._deriveWinners(uint32) (src/Lottery.sol#621-647)
	- Lottery._openNextRound(uint256,uint256) (src/Lottery.sol#551-569)
	- Lottery.buyTickets(uint32) (src/Lottery.sol#201-224)
	- Lottery.checkUpkeep(bytes) (src/Lottery.sol#239-248)
	- Lottery.fulfillRandomWords(uint256,uint256[]) (src/Lottery.sol#298-343)
	- Lottery.getRound(uint32) (src/Lottery.sol#442-469)
	- Lottery.injectPot(uint32,uint256) (src/Lottery.sol#227-234)
	- Lottery.ownerOfTicket(uint32,uint32) (src/Lottery.sol#436-439)
	- Lottery.pendingPrizes(uint32,address) (src/Lottery.sol#506-531)
	- Lottery.performUpkeep(bytes) (src/Lottery.sol#251-281)
	- Lottery.retryDraw(uint32) (src/Lottery.sol#284-294)
	- Lottery.rolloverExpired(uint32) (src/Lottery.sol#373-399)
	- Lottery.vrfRequestOf(uint32) (src/Lottery.sol#481-488)
	- Lottery.winnersOf(uint32) (src/Lottery.sol#496-503)
Reentrancy in Lottery.retryDraw(uint32) (src/Lottery.sol#284-294):
	External calls:
	- requestId = _requestRandomWords() (src/Lottery.sol#290)
		- s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))})) (src/Lottery.sol#572-583)
	State variables written after the call(s):
	- r.vrfRequestId = requestId (src/Lottery.sol#291)
	Lottery.s_rounds (src/Lottery.sol#126) can be used in cross function reentrancies:
	- Lottery._deriveWinners(uint32) (src/Lottery.sol#621-647)
	- Lottery._openNextRound(uint256,uint256) (src/Lottery.sol#551-569)
	- Lottery.buyTickets(uint32) (src/Lottery.sol#201-224)
	- Lottery.checkUpkeep(bytes) (src/Lottery.sol#239-248)
	- Lottery.fulfillRandomWords(uint256,uint256[]) (src/Lottery.sol#298-343)
	- Lottery.getRound(uint32) (src/Lottery.sol#442-469)
	- Lottery.injectPot(uint32,uint256) (src/Lottery.sol#227-234)
	- Lottery.ownerOfTicket(uint32,uint32) (src/Lottery.sol#436-439)
	- Lottery.pendingPrizes(uint32,address) (src/Lottery.sol#506-531)
	- Lottery.performUpkeep(bytes) (src/Lottery.sol#251-281)
	- Lottery.retryDraw(uint32) (src/Lottery.sol#284-294)
	- Lottery.rolloverExpired(uint32) (src/Lottery.sol#373-399)
	- Lottery.vrfRequestOf(uint32) (src/Lottery.sol#481-488)
	- Lottery.winnersOf(uint32) (src/Lottery.sol#496-503)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-2
INFO:Detectors:
Detector: reentrancy-benign
Reentrancy in Lottery.performUpkeep(bytes) (src/Lottery.sol#251-281):
	External calls:
	- requestId = _requestRandomWords() (src/Lottery.sol#275)
		- s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))})) (src/Lottery.sol#572-583)
	State variables written after the call(s):
	- _openNextRound(0,0) (src/Lottery.sol#280)
		- s_intervalCursor = cursor (src/Lottery.sol#560)
	- _openNextRound(0,0) (src/Lottery.sol#280)
		- s_lastSlotTime = t (src/Lottery.sol#559)
	- s_requestToRound[requestId] = roundId (src/Lottery.sol#277)
Reentrancy in Lottery.retryDraw(uint32) (src/Lottery.sol#284-294):
	External calls:
	- requestId = _requestRandomWords() (src/Lottery.sol#290)
		- s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))})) (src/Lottery.sol#572-583)
	State variables written after the call(s):
	- s_requestToRound[requestId] = roundId (src/Lottery.sol#292)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-3
INFO:Detectors:
Detector: reentrancy-events
Reentrancy in Lottery.performUpkeep(bytes) (src/Lottery.sol#251-281):
	External calls:
	- requestId = _requestRandomWords() (src/Lottery.sol#275)
		- s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))})) (src/Lottery.sol#572-583)
	Event emitted after the call(s):
	- DrawRequested(roundId,requestId) (src/Lottery.sol#278)
	- RoundOpened(newId,t) (src/Lottery.sol#568)
		- _openNextRound(0,0) (src/Lottery.sol#280)
Reentrancy in Lottery.retryDraw(uint32) (src/Lottery.sol#284-294):
	External calls:
	- requestId = _requestRandomWords() (src/Lottery.sol#290)
		- s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))})) (src/Lottery.sol#572-583)
	Event emitted after the call(s):
	- DrawRequested(roundId,requestId) (src/Lottery.sol#293)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-4
INFO:Detectors:
Detector: timestamp
Lottery.buyTickets(uint32) (src/Lottery.sol#201-224) uses timestamp for comparisons
	Dangerous comparisons:
	- block.timestamp >= r.closeTime (src/Lottery.sol#207)
Lottery.checkUpkeep(bytes) (src/Lottery.sol#239-248) uses timestamp for comparisons
	Dangerous comparisons:
	- upkeepNeeded = r.state == RoundState.OPEN && block.timestamp >= r.closeTime + SEAL_GAP (src/Lottery.sol#246)
Lottery.performUpkeep(bytes) (src/Lottery.sol#251-281) uses timestamp for comparisons
	Dangerous comparisons:
	- r.state != RoundState.OPEN || block.timestamp < r.closeTime + SEAL_GAP (src/Lottery.sol#254)
Lottery.retryDraw(uint32) (src/Lottery.sol#284-294) uses timestamp for comparisons
	Dangerous comparisons:
	- block.timestamp < r.drawRequestedAt + DRAW_TIMEOUT (src/Lottery.sol#287)
Lottery.claim(uint32,uint8) (src/Lottery.sol#348-370) uses timestamp for comparisons
	Dangerous comparisons:
	- block.timestamp > r.closeTime + CLAIM_WINDOW (src/Lottery.sol#352)
Lottery.rolloverExpired(uint32) (src/Lottery.sol#373-399) uses timestamp for comparisons
	Dangerous comparisons:
	- block.timestamp <= r.closeTime + CLAIM_WINDOW (src/Lottery.sol#376)
Lottery.ownerOfTicket(uint32,uint32) (src/Lottery.sol#436-439) uses timestamp for comparisons
	Dangerous comparisons:
	- ticketId >= s_rounds[roundId].ticketCount (src/Lottery.sol#437)
Lottery.winnersOf(uint32) (src/Lottery.sol#496-503) uses timestamp for comparisons
	Dangerous comparisons:
	- s_rounds[roundId].state != RoundState.SETTLED (src/Lottery.sol#501)
Lottery.pendingPrizes(uint32,address) (src/Lottery.sol#506-531) uses timestamp for comparisons
	Dangerous comparisons:
	- r.state != RoundState.SETTLED || block.timestamp > r.closeTime + CLAIM_WINDOW (src/Lottery.sol#514)
Lottery._openNextRound(uint256,uint256) (src/Lottery.sol#551-569) uses timestamp for comparisons
	Dangerous comparisons:
	- t <= block.timestamp (src/Lottery.sol#558)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#block-timestamp
INFO:Detectors:
Detector: pragma
6 different versions of Solidity are used:
	- Version constraint ^0.8.0 is used by:
		-^0.8.0 (lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol#1-2)
		-^0.8.0 (lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/access/ConfirmedOwner.sol#1-2)
		-^0.8.0 (lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/access/ConfirmedOwnerWithProposal.sol#1-2)
		-^0.8.0 (lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/IOwnable.sol#1-2)
		-^0.8.0 (lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol#1-2)
		-^0.8.0 (lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/interfaces/IVRFMigratableConsumerV2Plus.sol#1-2)
		-^0.8.0 (lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol#1-2)
	- Version constraint ^0.8.4 is used by:
		-^0.8.4 (lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol#1-2)
		-^0.8.4 (lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol#1-2)
	- Version constraint >=0.6.2 is used by:
		->=0.6.2 (lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#2-4)
		->=0.6.2 (lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol#2-4)
		->=0.6.2 (lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol#2-4)
	- Version constraint >=0.4.16 is used by:
		->=0.4.16 (lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#2-4)
		->=0.4.16 (lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#2-4)
		->=0.4.16 (lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#2-4)
		->=0.4.16 (lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#2-4)
	- Version constraint ^0.8.20 is used by:
		-^0.8.20 (lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#2-4)
		-^0.8.20 (lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol#2-4)
		-^0.8.20 (lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#3-5)
	- Version constraint 0.8.26 is used by:
		-0.8.26 (src/Lottery.sol#2)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#different-pragma-directives-are-used
INFO:Detectors:
Detector: cyclomatic-complexity
Lottery.constructor(address,uint256,bytes32,address,uint256,uint64,uint32[],address,uint16,uint16[],uint8[]) (src/Lottery.sol#149-196) has a high cyclomatic complexity (12).
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#cyclomatic-complexity
INFO:Detectors:
Detector: naming-convention
Variable Lottery.i_token (src/Lottery.sol#110) is not in mixedCase
Variable Lottery.i_ticketPrice (src/Lottery.sol#111) is not in mixedCase
Variable Lottery.i_keyHash (src/Lottery.sol#112) is not in mixedCase
Variable Lottery.i_subId (src/Lottery.sol#113) is not in mixedCase
Variable Lottery.s_currentRound (src/Lottery.sol#125) is not in mixedCase
Variable Lottery.s_treasury (src/Lottery.sol#131) is not in mixedCase
Variable Lottery.s_feeBps (src/Lottery.sol#132) is not in mixedCase
Variable Lottery.s_accruedFees (src/Lottery.sol#133) is not in mixedCase
Variable Lottery.s_salesPaused (src/Lottery.sol#134) is not in mixedCase
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#conformance-to-solidity-naming-conventions
INFO:Detectors:
Detector: immutable-states
Lottery.s_totalSlots (src/Lottery.sol#119) should be immutable 
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#state-variables-that-could-be-declared-immutable
**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [divide-before-multiply](#divide-before-multiply) (1 results) (Medium)
 - [reentrancy-no-eth](#reentrancy-no-eth) (2 results) (Medium)
 - [reentrancy-benign](#reentrancy-benign) (2 results) (Low)
 - [reentrancy-events](#reentrancy-events) (2 results) (Low)
 - [timestamp](#timestamp) (10 results) (Low)
 - [pragma](#pragma) (1 results) (Informational)
 - [cyclomatic-complexity](#cyclomatic-complexity) (1 results) (Informational)
 - [naming-convention](#naming-convention) (9 results) (Informational)
 - [immutable-states](#immutable-states) (1 results) (Optimization)
## divide-before-multiply
Impact: Medium
Confidence: Medium
 - [ ] ID-0
[Lottery.fulfillRandomWords(uint256,uint256[])](src/Lottery.sol#L298-L343) performs a multiplication on the result of a division:
	- [perWinner = amount / winners](src/Lottery.sol#L327)
	- [carryOut += amount - perWinner * winners](src/Lottery.sol#L329)

src/Lottery.sol#L298-L343


## reentrancy-no-eth
Impact: Medium
Confidence: Medium
 - [ ] ID-1
Reentrancy in [Lottery.retryDraw(uint32)](src/Lottery.sol#L284-L294):
	External calls:
	- [requestId = _requestRandomWords()](src/Lottery.sol#L290)
		- [s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))}))](src/Lottery.sol#L572-L583)
	State variables written after the call(s):
	- [r.vrfRequestId = requestId](src/Lottery.sol#L291)
	[Lottery.s_rounds](src/Lottery.sol#L126) can be used in cross function reentrancies:
	- [Lottery._deriveWinners(uint32)](src/Lottery.sol#L621-L647)
	- [Lottery._openNextRound(uint256,uint256)](src/Lottery.sol#L551-L569)
	- [Lottery.buyTickets(uint32)](src/Lottery.sol#L201-L224)
	- [Lottery.checkUpkeep(bytes)](src/Lottery.sol#L239-L248)
	- [Lottery.fulfillRandomWords(uint256,uint256[])](src/Lottery.sol#L298-L343)
	- [Lottery.getRound(uint32)](src/Lottery.sol#L442-L469)
	- [Lottery.injectPot(uint32,uint256)](src/Lottery.sol#L227-L234)
	- [Lottery.ownerOfTicket(uint32,uint32)](src/Lottery.sol#L436-L439)
	- [Lottery.pendingPrizes(uint32,address)](src/Lottery.sol#L506-L531)
	- [Lottery.performUpkeep(bytes)](src/Lottery.sol#L251-L281)
	- [Lottery.retryDraw(uint32)](src/Lottery.sol#L284-L294)
	- [Lottery.rolloverExpired(uint32)](src/Lottery.sol#L373-L399)
	- [Lottery.vrfRequestOf(uint32)](src/Lottery.sol#L481-L488)
	- [Lottery.winnersOf(uint32)](src/Lottery.sol#L496-L503)

src/Lottery.sol#L284-L294


 - [ ] ID-2
Reentrancy in [Lottery.performUpkeep(bytes)](src/Lottery.sol#L251-L281):
	External calls:
	- [requestId = _requestRandomWords()](src/Lottery.sol#L275)
		- [s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))}))](src/Lottery.sol#L572-L583)
	State variables written after the call(s):
	- [_openNextRound(0,0)](src/Lottery.sol#L280)
		- [newId = ++ s_currentRound](src/Lottery.sol#L562)
	[Lottery.s_currentRound](src/Lottery.sol#L125) can be used in cross function reentrancies:
	- [Lottery._openNextRound(uint256,uint256)](src/Lottery.sol#L551-L569)
	- [Lottery.buyTickets(uint32)](src/Lottery.sol#L201-L224)
	- [Lottery.checkUpkeep(bytes)](src/Lottery.sol#L239-L248)
	- [Lottery.fulfillRandomWords(uint256,uint256[])](src/Lottery.sol#L298-L343)
	- [Lottery.performUpkeep(bytes)](src/Lottery.sol#L251-L281)
	- [Lottery.rolloverExpired(uint32)](src/Lottery.sol#L373-L399)
	- [Lottery.s_currentRound](src/Lottery.sol#L125)
	- [r.vrfRequestId = requestId](src/Lottery.sol#L276)
	[Lottery.s_rounds](src/Lottery.sol#L126) can be used in cross function reentrancies:
	- [Lottery._deriveWinners(uint32)](src/Lottery.sol#L621-L647)
	- [Lottery._openNextRound(uint256,uint256)](src/Lottery.sol#L551-L569)
	- [Lottery.buyTickets(uint32)](src/Lottery.sol#L201-L224)
	- [Lottery.checkUpkeep(bytes)](src/Lottery.sol#L239-L248)
	- [Lottery.fulfillRandomWords(uint256,uint256[])](src/Lottery.sol#L298-L343)
	- [Lottery.getRound(uint32)](src/Lottery.sol#L442-L469)
	- [Lottery.injectPot(uint32,uint256)](src/Lottery.sol#L227-L234)
	- [Lottery.ownerOfTicket(uint32,uint32)](src/Lottery.sol#L436-L439)
	- [Lottery.pendingPrizes(uint32,address)](src/Lottery.sol#L506-L531)
	- [Lottery.performUpkeep(bytes)](src/Lottery.sol#L251-L281)
	- [Lottery.retryDraw(uint32)](src/Lottery.sol#L284-L294)
	- [Lottery.rolloverExpired(uint32)](src/Lottery.sol#L373-L399)
	- [Lottery.vrfRequestOf(uint32)](src/Lottery.sol#L481-L488)
	- [Lottery.winnersOf(uint32)](src/Lottery.sol#L496-L503)
	- [_openNextRound(0,0)](src/Lottery.sol#L280)
		- [r.state = RoundState.OPEN](src/Lottery.sol#L564)
		- [r.closeTime = t](src/Lottery.sol#L565)
		- [r.pot = carryPot](src/Lottery.sol#L566)
		- [r.tier1Carry = carryTier1](src/Lottery.sol#L567)
	[Lottery.s_rounds](src/Lottery.sol#L126) can be used in cross function reentrancies:
	- [Lottery._deriveWinners(uint32)](src/Lottery.sol#L621-L647)
	- [Lottery._openNextRound(uint256,uint256)](src/Lottery.sol#L551-L569)
	- [Lottery.buyTickets(uint32)](src/Lottery.sol#L201-L224)
	- [Lottery.checkUpkeep(bytes)](src/Lottery.sol#L239-L248)
	- [Lottery.fulfillRandomWords(uint256,uint256[])](src/Lottery.sol#L298-L343)
	- [Lottery.getRound(uint32)](src/Lottery.sol#L442-L469)
	- [Lottery.injectPot(uint32,uint256)](src/Lottery.sol#L227-L234)
	- [Lottery.ownerOfTicket(uint32,uint32)](src/Lottery.sol#L436-L439)
	- [Lottery.pendingPrizes(uint32,address)](src/Lottery.sol#L506-L531)
	- [Lottery.performUpkeep(bytes)](src/Lottery.sol#L251-L281)
	- [Lottery.retryDraw(uint32)](src/Lottery.sol#L284-L294)
	- [Lottery.rolloverExpired(uint32)](src/Lottery.sol#L373-L399)
	- [Lottery.vrfRequestOf(uint32)](src/Lottery.sol#L481-L488)
	- [Lottery.winnersOf(uint32)](src/Lottery.sol#L496-L503)

src/Lottery.sol#L251-L281


## reentrancy-benign
Impact: Low
Confidence: Medium
 - [ ] ID-3
Reentrancy in [Lottery.performUpkeep(bytes)](src/Lottery.sol#L251-L281):
	External calls:
	- [requestId = _requestRandomWords()](src/Lottery.sol#L275)
		- [s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))}))](src/Lottery.sol#L572-L583)
	State variables written after the call(s):
	- [_openNextRound(0,0)](src/Lottery.sol#L280)
		- [s_intervalCursor = cursor](src/Lottery.sol#L560)
	- [_openNextRound(0,0)](src/Lottery.sol#L280)
		- [s_lastSlotTime = t](src/Lottery.sol#L559)
	- [s_requestToRound[requestId] = roundId](src/Lottery.sol#L277)

src/Lottery.sol#L251-L281


 - [ ] ID-4
Reentrancy in [Lottery.retryDraw(uint32)](src/Lottery.sol#L284-L294):
	External calls:
	- [requestId = _requestRandomWords()](src/Lottery.sol#L290)
		- [s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))}))](src/Lottery.sol#L572-L583)
	State variables written after the call(s):
	- [s_requestToRound[requestId] = roundId](src/Lottery.sol#L292)

src/Lottery.sol#L284-L294


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-5
Reentrancy in [Lottery.retryDraw(uint32)](src/Lottery.sol#L284-L294):
	External calls:
	- [requestId = _requestRandomWords()](src/Lottery.sol#L290)
		- [s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))}))](src/Lottery.sol#L572-L583)
	Event emitted after the call(s):
	- [DrawRequested(roundId,requestId)](src/Lottery.sol#L293)
INFO:Slither:src/Lottery.sol analyzed (17 contracts with 102 detectors), 29 result(s) found

src/Lottery.sol#L284-L294


 - [ ] ID-6
Reentrancy in [Lottery.performUpkeep(bytes)](src/Lottery.sol#L251-L281):
	External calls:
	- [requestId = _requestRandomWords()](src/Lottery.sol#L275)
		- [s_vrfCoordinator.requestRandomWords(VRFV2PlusClient.RandomWordsRequest({keyHash:i_keyHash,subId:i_subId,requestConfirmations:VRF_CONFIRMATIONS,callbackGasLimit:VRF_CALLBACK_GAS,numWords:1,extraArgs:VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment:false}))}))](src/Lottery.sol#L572-L583)
	Event emitted after the call(s):
	- [DrawRequested(roundId,requestId)](src/Lottery.sol#L278)
	- [RoundOpened(newId,t)](src/Lottery.sol#L568)
		- [_openNextRound(0,0)](src/Lottery.sol#L280)

src/Lottery.sol#L251-L281


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-7
[Lottery.ownerOfTicket(uint32,uint32)](src/Lottery.sol#L436-L439) uses timestamp for comparisons
	Dangerous comparisons:
	- [ticketId >= s_rounds[roundId].ticketCount](src/Lottery.sol#L437)

src/Lottery.sol#L436-L439


 - [ ] ID-8
[Lottery.pendingPrizes(uint32,address)](src/Lottery.sol#L506-L531) uses timestamp for comparisons
	Dangerous comparisons:
	- [r.state != RoundState.SETTLED || block.timestamp > r.closeTime + CLAIM_WINDOW](src/Lottery.sol#L514)

src/Lottery.sol#L506-L531


 - [ ] ID-9
[Lottery.checkUpkeep(bytes)](src/Lottery.sol#L239-L248) uses timestamp for comparisons
	Dangerous comparisons:
	- [upkeepNeeded = r.state == RoundState.OPEN && block.timestamp >= r.closeTime + SEAL_GAP](src/Lottery.sol#L246)

src/Lottery.sol#L239-L248


 - [ ] ID-10
[Lottery.performUpkeep(bytes)](src/Lottery.sol#L251-L281) uses timestamp for comparisons
	Dangerous comparisons:
	- [r.state != RoundState.OPEN || block.timestamp < r.closeTime + SEAL_GAP](src/Lottery.sol#L254)

src/Lottery.sol#L251-L281


 - [ ] ID-11
[Lottery.rolloverExpired(uint32)](src/Lottery.sol#L373-L399) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= r.closeTime + CLAIM_WINDOW](src/Lottery.sol#L376)

src/Lottery.sol#L373-L399


 - [ ] ID-12
[Lottery._openNextRound(uint256,uint256)](src/Lottery.sol#L551-L569) uses timestamp for comparisons
	Dangerous comparisons:
	- [t <= block.timestamp](src/Lottery.sol#L558)

src/Lottery.sol#L551-L569


 - [ ] ID-13
[Lottery.buyTickets(uint32)](src/Lottery.sol#L201-L224) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= r.closeTime](src/Lottery.sol#L207)

src/Lottery.sol#L201-L224


 - [ ] ID-14
[Lottery.retryDraw(uint32)](src/Lottery.sol#L284-L294) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < r.drawRequestedAt + DRAW_TIMEOUT](src/Lottery.sol#L287)

src/Lottery.sol#L284-L294


 - [ ] ID-15
[Lottery.winnersOf(uint32)](src/Lottery.sol#L496-L503) uses timestamp for comparisons
	Dangerous comparisons:
	- [s_rounds[roundId].state != RoundState.SETTLED](src/Lottery.sol#L501)

src/Lottery.sol#L496-L503


 - [ ] ID-16
[Lottery.claim(uint32,uint8)](src/Lottery.sol#L348-L370) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > r.closeTime + CLAIM_WINDOW](src/Lottery.sol#L352)

src/Lottery.sol#L348-L370


## pragma
Impact: Informational
Confidence: High
 - [ ] ID-17
6 different versions of Solidity are used:
	- Version constraint ^0.8.0 is used by:
		-[^0.8.0](lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol#L1-L2)
		-[^0.8.0](lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/access/ConfirmedOwner.sol#L1-L2)
		-[^0.8.0](lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/access/ConfirmedOwnerWithProposal.sol#L1-L2)
		-[^0.8.0](lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/IOwnable.sol#L1-L2)
		-[^0.8.0](lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol#L1-L2)
		-[^0.8.0](lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/interfaces/IVRFMigratableConsumerV2Plus.sol#L1-L2)
		-[^0.8.0](lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol#L1-L2)
	- Version constraint ^0.8.4 is used by:
		-[^0.8.4](lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol#L1-L2)
		-[^0.8.4](lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol#L1-L2)
	- Version constraint >=0.6.2 is used by:
		-[>=0.6.2](lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#L2-L4)
		-[>=0.6.2](lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol#L2-L4)
		-[>=0.6.2](lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol#L2-L4)
	- Version constraint >=0.4.16 is used by:
		-[>=0.4.16](lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#L2-L4)
		-[>=0.4.16](lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#L2-L4)
		-[>=0.4.16](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L2-L4)
		-[>=0.4.16](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L2-L4)
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol#L2-L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L3-L5)
	- Version constraint 0.8.26 is used by:
		-[0.8.26](src/Lottery.sol#L2)

lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol#L1-L2


## cyclomatic-complexity
Impact: Informational
Confidence: High
 - [ ] ID-18
[Lottery.constructor(address,uint256,bytes32,address,uint256,uint64,uint32[],address,uint16,uint16[],uint8[])](src/Lottery.sol#L149-L196) has a high cyclomatic complexity (12).

src/Lottery.sol#L149-L196


## naming-convention
Impact: Informational
Confidence: High
 - [ ] ID-19
Variable [Lottery.s_accruedFees](src/Lottery.sol#L133) is not in mixedCase

src/Lottery.sol#L133


 - [ ] ID-20
Variable [Lottery.s_salesPaused](src/Lottery.sol#L134) is not in mixedCase

src/Lottery.sol#L134


 - [ ] ID-21
Variable [Lottery.i_keyHash](src/Lottery.sol#L112) is not in mixedCase

src/Lottery.sol#L112


 - [ ] ID-22
Variable [Lottery.s_treasury](src/Lottery.sol#L131) is not in mixedCase

src/Lottery.sol#L131


 - [ ] ID-23
Variable [Lottery.i_subId](src/Lottery.sol#L113) is not in mixedCase

src/Lottery.sol#L113


 - [ ] ID-24
Variable [Lottery.s_currentRound](src/Lottery.sol#L125) is not in mixedCase

src/Lottery.sol#L125


 - [ ] ID-25
Variable [Lottery.i_token](src/Lottery.sol#L110) is not in mixedCase

src/Lottery.sol#L110


 - [ ] ID-26
Variable [Lottery.i_ticketPrice](src/Lottery.sol#L111) is not in mixedCase

src/Lottery.sol#L111


 - [ ] ID-27
Variable [Lottery.s_feeBps](src/Lottery.sol#L132) is not in mixedCase

src/Lottery.sol#L132


## immutable-states
Impact: Optimization
Confidence: High
 - [ ] ID-28
[Lottery.s_totalSlots](src/Lottery.sol#L119) should be immutable 

src/Lottery.sol#L119


