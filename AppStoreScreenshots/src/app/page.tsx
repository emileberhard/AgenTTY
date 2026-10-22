"use client"

import { toPng } from "html-to-image"
import JSZip from "jszip"
import { useCallback, useRef, useState } from "react"
import copyJson from "./copy.json"

type DeviceKind = "iphone" | "ipad"

type SlideCopy = {
  slug: string
  headline: string
  subtitle: string
}

type Device = {
  kind: DeviceKind
  label: string
  width: number
  height: number
  ascType: string
  capturePrefix: string
}

const slides = copyJson["en-US"] satisfies SlideCopy[]

const allDevices: Device[] = [
  {
    kind: "iphone",
    label: "iPhone 17 Pro Max",
    width: 1320,
    height: 2868,
    ascType: "APP_IPHONE_69",
    capturePrefix: "AgenTTY iPhone 17 Pro Max Screenshots iOS 26.5",
  },
  {
    kind: "ipad",
    label: "iPad Pro 13-inch (M5)",
    width: 2064,
    height: 2752,
    ascType: "APP_IPAD_PRO_3GEN_129",
    capturePrefix: "AgenTTY iPad Pro 13-inch Screenshots iOS 26.5",
  },
]

const selectedDeviceKinds = new Set(
  (process.env.NEXT_PUBLIC_AGENTTY_SCREENSHOT_DEVICES ?? "iphone,ipad").split(
    ",",
  ),
)
const devices = allDevices.filter((device) =>
  selectedDeviceKinds.has(device.kind),
)

function screenshotSource(device: Device, index: number, slide: SlideCopy) {
  const prefix = String(index + 1).padStart(2, "0")
  return `/framed/en-US/${device.capturePrefix}-${prefix}-${slide.slug}.png`
}

function Slide({
  device,
  slide,
  index,
}: {
  device: Device
  slide: SlideCopy
  index: number
}) {
  const isPhone = device.kind === "iphone"
  const deviceWidth = isPhone ? device.width * 0.84 : device.width * 0.79
  const top = isPhone ? device.height * 0.22 : device.height * 0.235
  const headlineWidth = isPhone ? "88%" : "82%"
  const headlineSize = isPhone ? device.width * 0.064 : device.width * 0.058
  const subtitleSize = isPhone ? device.width * 0.032 : device.width * 0.025
  const deviceOffset = [0, -0.7, 0.5, -0.4, 0.7][index] ?? 0

  return (
    <div
      style={{
        position: "relative",
        width: device.width,
        height: device.height,
        overflow: "hidden",
        background:
          "radial-gradient(circle at 78% 4%, rgba(87, 160, 173, 0.16), transparent 38%), linear-gradient(155deg, #071b22 0%, #102e37 56%, #285965 100%)",
        color: "#f8fbfc",
        fontFamily:
          '"Avenir Next", "SF Pro Rounded", "SF Pro Display", sans-serif',
      }}
    >
      <div
        style={{
          position: "absolute",
          top: isPhone ? device.height * 0.046 : device.height * 0.055,
          left: "50%",
          width: headlineWidth,
          transform: "translateX(-50%)",
          textAlign: "center",
          zIndex: 2,
        }}
      >
        <h1
          style={{
            margin: 0,
            fontSize: headlineSize,
            fontWeight: 750,
            letterSpacing: -headlineSize * 0.035,
            lineHeight: 1.03,
            textWrap: "balance",
            textShadow: "0 3px 14px rgba(0, 0, 0, 0.24)",
          }}
        >
          {slide.headline}
        </h1>
        <p
          style={{
            margin: `${subtitleSize * 0.58}px 0 0`,
            fontSize: subtitleSize,
            fontWeight: 450,
            lineHeight: 1.25,
            letterSpacing: -subtitleSize * 0.01,
            color: "rgba(228, 239, 242, 0.78)",
            textWrap: "balance",
          }}
        >
          {slide.subtitle}
        </p>
      </div>

      <img
        src={screenshotSource(device, index, slide)}
        alt=""
        draggable={false}
        style={{
          position: "absolute",
          top,
          left: "50%",
          width: deviceWidth,
          height: "auto",
          transform: `translateX(-50%) rotate(${deviceOffset}deg)`,
          filter: "drop-shadow(0 34px 42px rgba(0, 0, 0, 0.44))",
          userSelect: "none",
        }}
      />
    </div>
  )
}

function dataUrlBytes(dataUrl: string) {
  const binary = atob(dataUrl.split(",")[1])
  return Uint8Array.from(binary, (character) => character.charCodeAt(0))
}

async function capture(element: HTMLElement, device: Device) {
  const wrapper = element.parentElement
  if (!wrapper) throw new Error("Missing export wrapper")

  wrapper.style.left = "0"
  wrapper.style.opacity = "1"
  wrapper.style.zIndex = "-1"
  const options = {
    width: device.width,
    height: device.height,
    pixelRatio: 1,
    cacheBust: true,
  }
  try {
    await toPng(element, options)
    return await toPng(element, options)
  } finally {
    wrapper.style.left = "-9999px"
    wrapper.style.opacity = ""
    wrapper.style.zIndex = ""
  }
}

export default function ScreenshotsPage() {
  const exportElements = useRef(new Map<string, HTMLDivElement>())
  const [isExporting, setIsExporting] = useState(false)

  const exportAll = useCallback(async () => {
    setIsExporting(true)
    try {
      const zip = new JSZip()
      for (const device of devices) {
        for (const [index, slide] of slides.entries()) {
          const element = exportElements.current.get(`${device.kind}-${index}`)
          if (!element)
            throw new Error(`Missing export element: ${device.kind}-${index}`)
          const dataUrl = await capture(element, device)
          const prefix = String(index + 1).padStart(2, "0")
          zip.file(
            `en-US/${device.ascType}/${prefix}_${slide.slug}.png`,
            dataUrlBytes(dataUrl),
          )
        }
      }

      const blob = await zip.generateAsync({ type: "blob" })
      const url = URL.createObjectURL(blob)
      const anchor = document.createElement("a")
      anchor.href = url
      anchor.download = "agentty-app-store-screenshots.zip"
      anchor.click()
      URL.revokeObjectURL(url)
    } finally {
      setIsExporting(false)
    }
  }, [])

  return (
    <main
      style={{ maxWidth: 1480, margin: "0 auto", padding: "36px 28px 80px" }}
    >
      <header
        style={{
          display: "flex",
          alignItems: "center",
          gap: 20,
          marginBottom: 40,
        }}
      >
        <div>
          <div
            style={{
              color: "#69d6e9",
              fontSize: 13,
              fontWeight: 700,
              letterSpacing: 1.4,
            }}
          >
            AGENTTY
          </div>
          <h1 style={{ margin: "3px 0 0", fontSize: 30 }}>App Store artwork</h1>
        </div>
        <div style={{ flex: 1 }} />
        <button
          type="button"
          data-export-all
          disabled={isExporting}
          onClick={exportAll}
          style={{
            border: "1px solid rgba(152, 231, 243, 0.42)",
            borderRadius: 999,
            padding: "11px 19px",
            background: isExporting ? "#23434a" : "#55bfd1",
            color: "#06171b",
            fontWeight: 750,
            cursor: isExporting ? "wait" : "pointer",
          }}
        >
          {isExporting ? "Exporting…" : "Export all"}
        </button>
      </header>

      {devices.map((device) => (
        <section key={device.kind} style={{ marginTop: 44 }}>
          <h2
            style={{
              margin: "0 0 18px",
              color: "rgba(237, 247, 249, 0.8)",
              fontSize: 18,
            }}
          >
            {device.label} · {device.width}×{device.height}
          </h2>
          <div
            style={{
              display: "grid",
              gridTemplateColumns:
                device.kind === "iphone"
                  ? "repeat(5, minmax(0, 1fr))"
                  : "repeat(3, minmax(0, 1fr))",
              gap: 16,
              alignItems: "start",
            }}
          >
            {slides.map((slide, index) => {
              const scale = device.kind === "iphone" ? 0.18 : 0.205
              return (
                <div
                  key={slide.slug}
                  style={{
                    width: "100%",
                    aspectRatio: `${device.width} / ${device.height}`,
                    overflow: "hidden",
                    borderRadius: 13,
                    outline: "1px solid rgba(136, 206, 219, 0.18)",
                    background: "#102b33",
                  }}
                >
                  <div
                    style={{
                      transform: `scale(${scale})`,
                      transformOrigin: "top left",
                    }}
                  >
                    <Slide device={device} slide={slide} index={index} />
                  </div>
                </div>
              )
            })}
          </div>
        </section>
      ))}

      {devices.flatMap((device) =>
        slides.map((slide, index) => (
          <div
            key={`export-${device.kind}-${slide.slug}`}
            style={{ position: "absolute", left: -9999 }}
            ref={(wrapper) => {
              const child = wrapper?.firstElementChild
              if (child instanceof HTMLDivElement) {
                exportElements.current.set(`${device.kind}-${index}`, child)
              }
            }}
          >
            <Slide device={device} slide={slide} index={index} />
          </div>
        )),
      )}
    </main>
  )
}
