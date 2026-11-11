// Screenshots of the running site at phone and desktop widths: node scripts/shots.mjs <outDir> <path>...
import { chromium } from '@playwright/test'

const [out, ...paths] = process.argv.slice(2)
const browser = await chromium.launch()
for (const [name, width] of [['desktop', 1280], ['phone', 390]]) {
  const page = await browser.newPage({ viewport: { width, height: 900 } })
  const problems = []
  page.on('console', message => { if (message.type() === 'error') problems.push(message.text().slice(0, 300)) })
  page.on('pageerror', error => problems.push(String(error).slice(0, 300)))
  for (const path of paths) {
    await page.goto(`http://localhost:8790${path}`, { waitUntil: 'networkidle' }).catch(error => problems.push(String(error)))
    await page.waitForTimeout(4000)
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    await page.screenshot({ path: `${out}/${name}${path.replace(/[^a-z0-9]/gi, '_') || '_home'}.png`, fullPage: true })
    console.log(name, path, 'overflow', overflow, problems.length ? problems : 'no errors')
    problems.length = 0
  }
  await page.close()
}
await browser.close()
