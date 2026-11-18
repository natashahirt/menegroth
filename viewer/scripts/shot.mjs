// Load the viewer in a headless Chrome (started with --remote-debugging-port),
// wait for the scene, optionally click buttons, then save a screenshot and
// print the info line. Usage: node --experimental-websocket scripts/shot.mjs out.png [buttonId ...]
import fs from "node:fs"

const port = process.env.CDP_PORT ?? "9333"
const out = process.argv[2] ?? "shot.png"
const clicks = process.argv.slice(3)

const target = await (await fetch(`http://127.0.0.1:${port}/json/new?http://localhost:5173/`, { method: "PUT" })).json()
const ws = new WebSocket(target.webSocketDebuggerUrl)
await new Promise((resolve) => ws.addEventListener("open", resolve, { once: true }))
let next = 0
const pending = new Map()
ws.addEventListener("message", (event) => {
  const msg = JSON.parse(event.data)
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg)
    pending.delete(msg.id)
  }
  if (msg.method === "Runtime.consoleAPICalled") {
    console.log("console:", msg.params.args.map((a) => a.value ?? a.description).join(" "))
  }
  if (msg.method === "Runtime.exceptionThrown") {
    console.log("exception:", msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text)
  }
})
const send = (method, params = {}) => new Promise((resolve) => {
  const id = ++next
  pending.set(id, resolve)
  ws.send(JSON.stringify({ id, method, params }))
})
const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true })).result?.result?.value
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

await send("Runtime.enable")
await send("Emulation.setDeviceMetricsOverride", { width: 1400, height: 900, deviceScaleFactor: Number(process.env.DPR ?? 1), mobile: false })
for (let i = 0; i < 120; i++) {
  const status = await evaluate("document.querySelector('#status')?.textContent ?? ''")
  if (/nodes/.test(status)) break
  await sleep(500)
}
await sleep(1500)
for (const id of clicks) {
  await evaluate(`document.querySelector('#${id}')?.click()`)
  await sleep(1500)
}
console.log("status:", await evaluate("document.querySelector('#status').textContent"))
console.log("info:", await evaluate("document.querySelector('#info').textContent"))
console.log("hash:", await evaluate("location.hash"))
const shot = await send("Page.captureScreenshot", { format: "png" })
fs.writeFileSync(out, Buffer.from(shot.result.data, "base64"))
await fetch(`http://127.0.0.1:${port}/json/close/${target.id}`)
ws.close()
