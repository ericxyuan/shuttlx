import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "ShuttlX · Your game, a clearer picture",
  description: "Badminton sessions, swing patterns and personal bests. Connect your Apple Watch directly to ShuttlX on the web.",
  other: {
    "codex-preview": "development",
  },
  icons: {
    icon: "/master-icon.png",
    shortcut: "/master-icon.png",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className="antialiased">{children}</body>
    </html>
  );
}
