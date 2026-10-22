import type { Metadata } from "next"
import type { ReactNode } from "react"
import "./styles.css"

export const metadata: Metadata = {
  title: "AgenTTY App Store Screenshots",
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
