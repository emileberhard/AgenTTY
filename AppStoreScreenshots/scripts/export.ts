import { mkdir } from "node:fs/promises"
import { chromium } from "playwright-core"

const port = 4317
const url = `http://127.0.0.1:${port}`
const outputDirectory = new URL("../output/", import.meta.url)
const outputPath = new URL("agentty-app-store-screenshots.zip", outputDirectory)
const chromePath =
  process.env.AGENTTY_SCREENSHOT_CHROME_PATH ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const screenshotDevices =
  process.env.AGENTTY_SCREENSHOT_DEVICES ?? "iphone,ipad"

await mkdir(outputDirectory, { recursive: true })

const server = Bun.spawn(
  ["bun", "run", "dev", "--hostname", "127.0.0.1", "--port", String(port)],
  {
    cwd: new URL("..", import.meta.url).pathname,
    env: {
      ...process.env,
      NEXT_PUBLIC_AGENTTY_SCREENSHOT_DEVICES: screenshotDevices,
    },
    stdout: "inherit",
    stderr: "inherit",
  },
)

try {
  let serverReady = false
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const response = await fetch(url)
      if (response.ok) {
        serverReady = true
        break
      }
    } catch {}
    await Bun.sleep(250)
  }
  if (!serverReady)
    throw new Error("Screenshot preview server did not become ready")

  const browser = await chromium.launch({
    executablePath: chromePath,
    headless: true,
  })
  try {
    const page = await browser.newPage({
      viewport: { width: 1500, height: 1000 },
      deviceScaleFactor: 1,
    })
    await page.goto(url, { waitUntil: "networkidle" })
    await page.waitForFunction(() =>
      Array.from(document.images).every(
        (image) => image.complete && image.naturalWidth > 0,
      ),
    )
    const downloadPromise = page.waitForEvent("download")
    await page.locator("[data-export-all]").click()
    const download = await downloadPromise
    await download.saveAs(outputPath.pathname)
    console.log(outputPath.pathname)
  } finally {
    await browser.close()
  }
} finally {
  server.kill()
  await server.exited
}
