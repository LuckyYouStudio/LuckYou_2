// 从 contracts/out 同步 ABI 到前端（FR-W-07：不手抄 ABI）
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "..", "contracts", "out");
const dest = join(root, "src", "lib", "abi");
mkdirSync(dest, { recursive: true });

const artifacts = [
  ["Lottery.sol/Lottery.json", "Lottery.json"],
  ["MockERC20.sol/MockERC20.json", "MockERC20.json"],
  ["VRFCoordinatorV2_5Mock.sol/VRFCoordinatorV2_5Mock.json", "VRFCoordinatorV2_5Mock.json"],
];

for (const [src, name] of artifacts) {
  const artifact = JSON.parse(readFileSync(join(out, src), "utf8"));
  writeFileSync(join(dest, name), JSON.stringify(artifact.abi, null, 2));
  console.log(`synced ${name} (${artifact.abi.length} entries)`);
}
