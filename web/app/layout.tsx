import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "LuckYou 本地测试台",
  description: "链上周期彩票 · anvil 本地测试界面",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}
