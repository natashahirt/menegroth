import { decodeScene } from "./decode"

self.onmessage = async (event: MessageEvent<ArrayBuffer>) => {
  try {
    const decoded = await decodeScene(event.data)
    const transfers = Object.values(decoded.arrays)
    if (decoded.variants) {
      for (const block of Object.values(decoded.variants.blocks)) transfers.push(block.gzip)
    }
    self.postMessage({
      ok: true,
      header: decoded.header,
      arrays: decoded.arrays,
      variants: decoded.variants,
      variantId: decoded.variantId,
    }, { transfer: transfers })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    self.postMessage({ ok: false, message })
  }
}
