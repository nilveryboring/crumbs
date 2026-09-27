import { createRequire } from 'module'
const require = createRequire(import.meta.url)
const { chromium } = require('playwright')
import fs from 'fs'

const [mode, arg] = process.argv.slice(2)
const dir = new URL('.', import.meta.url).pathname
const browser = await chromium.launch()
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 })
await page.goto('file://' + dir + 'index.html')
await page.evaluate(() => Promise.all([...document.images].map((i) => i.decode())))
await page.evaluate(() => document.fonts.ready)

if (mode === 'stills') {
  for (const t of arg.split(',').map(Number)) {
    await page.evaluate((t) => window.render(t), t)
    await page.screenshot({ path: `${dir}still-${t}.png` })
  }
} else {
  const fps = 30
  const duration = await page.evaluate(() => window.DURATION)
  fs.mkdirSync(dir + 'frames', { recursive: true })
  const n = Math.round(duration * fps)
  for (let f = 0; f < n; f++) {
    await page.evaluate((t) => window.render(t), f / fps)
    await page.screenshot({ path: `${dir}frames/${String(f).padStart(5, '0')}.jpg`, type: 'jpeg', quality: 94 })
  }
  console.log('frames', n)
}
await browser.close()
