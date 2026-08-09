import type { Metadata } from "next";
import "./globals.css";

const isLocal = (process.env.NEXT_PUBLIC_NETWORK ?? "local") === "local";

export const metadata: Metadata = {
  title: isLocal ? "LuckYou 本地测试台" : "LuckYou · Base Sepolia 测试站",
  description: isLocal ? "链上周期彩票 · anvil 本地测试界面" : "链上周期彩票 · Chainlink VRF 开奖 · Base Sepolia 测试网",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}
