/**
 * Text out of the .docx / .xlsx / .pptx files the ONLYOFFICE editor exports, for Claude's read tools
 * (a PDF is read from its .docx export: ONLYOFFICE puts each page in a section of its own).
 * The zip is read with the browser's own DecompressionStream; the XML with DOMParser.
 */

type Zip = Map<string, () => Promise<string>>

export async function unzip(buf: ArrayBuffer): Promise<Zip> {
  const d = new DataView(buf)
  const u = new Uint8Array(buf)
  // end of central directory: the last 22+ bytes
  let e = u.length - 22
  while (e >= 0 && d.getUint32(e, true) !== 0x06054b50) e--
  if (e < 0) throw new Error('the editor returned a file that is not a zip')
  const count = d.getUint16(e + 10, true)
  let p = d.getUint32(e + 16, true)
  const utf8 = new TextDecoder()
  const out: Zip = new Map()
  for (let i = 0; i < count; i++) {
    const method = d.getUint16(p + 10, true)
    const size = d.getUint32(p + 20, true)
    const nameLen = d.getUint16(p + 28, true)
    const offset = d.getUint32(p + 42, true)
    const name = utf8.decode(u.subarray(p + 46, p + 46 + nameLen))
    p += 46 + nameLen + d.getUint16(p + 30, true) + d.getUint16(p + 32, true)
    out.set(name, async () => {
      const start = offset + 30 + d.getUint16(offset + 26, true) + d.getUint16(offset + 28, true)
      const raw = u.subarray(start, start + size)
      if (method === 0) return utf8.decode(raw)
      return new Response(new Blob([raw]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).text()
    })
  }
  return out
}

async function xml(z: Zip, name: string): Promise<Element | null> {
  const f = z.get(name)
  return f ? new DOMParser().parseFromString(await f(), 'application/xml').documentElement : null
}

const kids = (el: Element, name: string): Element[] => Array.from(el.children).filter((c) => c.localName === name)

/** a part's relationships: Id → zip path */
async function rels(z: Zip, dir: string, part: string): Promise<Map<string, string>> {
  const r = await xml(z, `${dir}/_rels/${part}.rels`)
  const m = new Map<string, string>()
  for (const el of r ? kids(r, 'Relationship') : []) {
    const t = el.getAttribute('Target') ?? ''
    m.set(el.getAttribute('Id') ?? '', t.startsWith('/') ? t.slice(1) : `${dir}/${t}`)
  }
  return m
}
const relId = (el: Element): string => el.getAttribute('r:id') ?? ''

/** marks the end of a PDF page in `lines` */
const PAGE = '\f'

/**
 * Paragraphs (w:p of Word, a:p of slides) as lines, tables as rows of cells joined by " | ".
 * A paragraph holding a section break ends a page (a `PAGE` line).
 */
function lines(el: Element, out: string[]): void {
  for (const c of Array.from(el.children)) {
    const n = c.localName
    if (n === 'Fallback') continue // mc:AlternateContent repeats its content
    if (n === 'p') {
      const s = { text: '' }
      para(c, s, out)
      out.push(s.text)
      if (kids(c, 'pPr').some((p) => kids(p, 'sectPr').length)) out.push(PAGE)
    } else if (n === 'tbl') {
      for (const tr of kids(c, 'tr'))
        out.push(
          kids(tr, 'tc')
            .map((tc) => {
              const cell: string[] = []
              lines(tc, cell)
              return cell.filter((l) => l.trim() && l !== PAGE).join(' ')
            })
            .join(' | ')
        )
    } else lines(c, out)
  }
}

function para(el: Element, s: { text: string }, out: string[]): void {
  for (const c of Array.from(el.children)) {
    switch (c.localName) {
      case 'Fallback':
      case 'pPr':
      case 'rPr':
        break
      case 't':
        s.text += c.textContent ?? ''
        break
      case 'tab':
        s.text += '\t'
        break
      case 'br':
      case 'cr':
        s.text += '\n'
        break
      case 'txbxContent': // a text box: its own lines
        lines(c, out)
        break
      default:
        para(c, s, out)
    }
  }
}

/** lines joined, without runs of empty ones */
const tidy = (ls: string[]): string =>
  ls
    .join('\n')
    .replace(/[ \t]+$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim()

/** "1-5", "3", "1,4-6" → page / slide numbers (default: the first 20) */
export function pageList(spec: unknown, n: number): number[] {
  if (typeof spec !== 'string' || !spec.trim()) return Array.from({ length: Math.min(n, 20) }, (_, i) => i + 1)
  const out: number[] = []
  for (const part of spec.split(',')) {
    const [a, b] = part.split('-').map((x) => Number(x.trim()))
    if (!a) continue
    for (let p = a; p <= (b || a) && p <= n; p++) if (p >= 1 && !out.includes(p)) out.push(p)
  }
  return out
}

/* ---------------- Word ---------------- */

export async function docText(z: Zip): Promise<string> {
  const body = (await xml(z, 'word/document.xml'))?.getElementsByTagNameNS('*', 'body')[0]
  if (!body) throw new Error('the document has no body')
  const out: string[] = []
  lines(body, out)
  return tidy(out.filter((l) => l !== PAGE))
}

/* ---------------- PDF (its .docx export) ---------------- */

export async function pdfPages(z: Zip): Promise<string[]> {
  const body = (await xml(z, 'word/document.xml'))?.getElementsByTagNameNS('*', 'body')[0]
  if (!body) throw new Error('the PDF has no pages')
  const out: string[] = []
  lines(body, out)
  const pages = out
    .join('\n')
    .split(PAGE)
    .map((p) => tidy(p.split('\n')))
  if (pages.length > 1 && !pages[pages.length - 1]) pages.pop()
  return pages
}

/* ---------------- PowerPoint ---------------- */

export async function slideTexts(z: Zip): Promise<string[]> {
  const pres = await xml(z, 'ppt/presentation.xml')
  if (!pres) throw new Error('the presentation has no slides list')
  const r = await rels(z, 'ppt', 'presentation.xml')
  const out: string[] = []
  for (const id of Array.from(pres.getElementsByTagNameNS('*', 'sldId'))) {
    const slide = await xml(z, r.get(relId(id)) ?? '')
    const ls: string[] = []
    if (slide) lines(slide, ls)
    out.push(tidy(ls))
  }
  return out
}

/* ---------------- Excel ---------------- */

function colName(c: number): string {
  let s = ''
  for (let n = c; n >= 0; n = Math.floor(n / 26) - 1) s = String.fromCharCode(65 + (n % 26)) + s
  return s
}

/** "B12" → { r: 11, c: 1 } */
function parseCell(a: string): { r: number; c: number } {
  const m = /^\$?([A-Za-z]+)\$?(\d+)$/.exec(a.trim())
  if (!m || Number(m[2]) < 1) throw new Error(`not a cell: ${a}`)
  const c = m[1].toUpperCase().split('').reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1
  return { r: Number(m[2]) - 1, c }
}

/** text of a shared / inline string, without its phonetic runs */
const stringText = (el: Element): string =>
  Array.from(el.getElementsByTagNameNS('*', 't'))
    .filter((t) => t.parentElement?.localName !== 'rPh')
    .map((t) => t.textContent ?? '')
    .join('')

/**
 * One sheet's cells as tab-separated rows, each starting with its row number; the first lines name
 * the workbook's sheets and the columns. Values are as stored (no number formats: dates are serial
 * numbers); formula cells add ` [=FORMULA]`. Default: the first 200 rows of the active sheet.
 */
export async function sheetText(z: Zip, sheetName?: string, range?: string): Promise<string> {
  const wb = await xml(z, 'xl/workbook.xml')
  if (!wb) throw new Error('the workbook has no sheets list')
  const sheets = Array.from(wb.getElementsByTagNameNS('*', 'sheet'))
  const names = sheets.map((s) => s.getAttribute('name') ?? '')
  const active = Number(wb.getElementsByTagNameNS('*', 'workbookView')[0]?.getAttribute('activeTab') ?? 0)
  const i = sheetName ? names.findIndex((n) => n.toLowerCase() === sheetName.toLowerCase()) : Math.min(active, sheets.length - 1)
  if (i < 0) throw new Error(`no sheet "${sheetName}" (sheets: ${names.join(', ')})`)
  const ws = await xml(z, (await rels(z, 'xl', 'workbook.xml')).get(relId(sheets[i])) ?? '')
  if (!ws) throw new Error(`sheet "${names[i]}" is missing from the file`)
  const sst = await xml(z, 'xl/sharedStrings.xml')
  const strings = sst ? kids(sst, 'si').map(stringText) : []

  const cells = new Map<string, string>()
  let rows = 0
  let cols = 0
  for (const row of Array.from(ws.getElementsByTagNameNS('*', 'row'))) {
    let next = 0
    for (const c of kids(row, 'c')) {
      const ref = c.getAttribute('r')
      const { r, c: col } = ref ? parseCell(ref) : { r: Number(row.getAttribute('r')) - 1, c: next }
      next = col + 1
      const v = kids(c, 'v')[0]?.textContent ?? ''
      const t = c.getAttribute('t')
      let text = t === 's' ? (strings[Number(v)] ?? '') : t === 'b' ? (v === '1' ? 'TRUE' : 'FALSE') : t === 'inlineStr' ? stringText(c) : v
      text = text.replace(/[\t\r\n]+/g, ' ')
      const f = kids(c, 'f')[0]?.textContent
      if (f) text += ` [=${f}]`
      if (!text) continue
      cells.set(`${r}:${col}`, text)
      rows = Math.max(rows, r + 1)
      cols = Math.max(cols, col + 1)
    }
  }

  let r0 = 0
  let c0 = 0
  let r1 = Math.min(199, rows - 1)
  let c1 = cols - 1
  if (range) {
    const [a, b = a] = range.split(':')
    ;({ r: r0, c: c0 } = parseCell(a))
    ;({ r: r1, c: c1 } = parseCell(b))
  }
  r1 = Math.min(r1, rows - 1, r0 + 999)
  c1 = Math.min(c1, cols - 1)
  const head = [`Sheets: ${names.map((n) => `"${n}"`).join(', ')}`, `Sheet "${names[i]}" (${rows} rows × ${cols} columns used)`]
  if (r0 > r1 || c0 > c1) return [...head, 'No cells in that range.'].join('\n')
  const out = [...head, ['#', ...Array.from({ length: c1 - c0 + 1 }, (_, k) => colName(c0 + k))].join('\t')]
  for (let r = r0; r <= r1; r++) {
    const line = [String(r + 1)]
    for (let c = c0; c <= c1; c++) line.push(cells.get(`${r}:${c}`) ?? '')
    out.push(line.join('\t'))
  }
  return out.join('\n')
}
