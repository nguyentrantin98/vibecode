import { useEffect, useRef, useState } from 'react'
import { ArrowLeft, ArrowRight, ExternalLink, Laptop, Maximize, Monitor, RotateCw, Eraser, Search, ShieldCheck, ShieldOff, Shuffle, Smartphone, Star, Tablet, X } from 'lucide-react'
import type { WebSuggestion } from '../../../shared/types'
import { BookmarkBar } from './BrowserBookmarks'
import { ExtensionsButton } from './BrowserExtensions'
import { useStore } from '../store'
import { HOME_URL, newBrowserTab, setBrowserUrl } from '../actions'
import { SlidePill } from './motion'
import { useT, type T } from '../i18n'

/** transitions that never move anything (a slide or scale can move the page, so those still count) */
const COLOR_ONLY = new Set(['background-color', 'color', 'opacity', 'box-shadow', 'border-color', 'outline-color', 'fill', 'stroke', 'text-decoration-color'])

/** Typed text → URL: keep real URLs, add https:// to bare hosts, search everything else. */
function toUrl(input: string): string {
  const t = input.trim()
  if (/^(https?|file):\/\//i.test(t)) return t
  if (/^localhost(:\d+)?(\/|$)/i.test(t) || /^\d{1,3}(\.\d{1,3}){3}(:\d+)?(\/|$)/.test(t)) return 'http://' + t
  if (/^[\w-]+(\.[\w-]+)+(:\d+)?(\/\S*)?$/.test(t)) return 'https://' + t
  return 'https://www.google.com/search?q=' + encodeURIComponent(t)
}

/** The blank start page shows as an empty address bar. */
const display = (url: string): string => (url === HOME_URL ? '' : url)

/* ---------------- device emulation ---------------- */

const MOBILE_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'
const TABLET_UA =
  'Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'

interface Device {
  key: string
  label: (t: T) => string
  icon: React.JSX.Element
  w?: number
  h?: number
  /** phones/tablets also get a mobile browser identity, so sites serve their mobile layout */
  ua?: string
}

const DEVICES: Device[] = [
  { key: 'fit', label: (t) => t('Fit', 'Vừa khung'), icon: <Maximize size={13} /> },
  { key: 'fhd', label: () => 'Full HD 1920×1080', icon: <Monitor size={13} />, w: 1920, h: 1080 },
  { key: 'laptop', label: (t) => t('Laptop 1366×768', 'Máy tính xách tay 1366×768'), icon: <Laptop size={13} />, w: 1366, h: 768 },
  { key: 'ipad', label: () => 'iPad 820×1180', icon: <Tablet size={13} />, w: 820, h: 1180, ua: TABLET_UA },
  { key: 'mobile', label: (t) => t('Mobile 390×844', 'Điện thoại 390×844'), icon: <Smartphone size={13} />, w: 390, h: 844, ua: MOBILE_UA }
]

const DEVICE_KEY = 'vibe.browserDevice'
function savedDevice(): string {
  try {
    return localStorage.getItem(DEVICE_KEY) ?? 'fit'
  } catch {
    return 'fit'
  }
}

/**
 * Anything drawn over the page area (menus, dialogs, lightboxes, address suggestions). The page
 * itself is a native view stacked above the app's HTML, so it steps aside while one is open.
 */
const OVERLAYS = '.overlay, .menu, .ctx-menu, .ctx-pop, .image-lightbox, .term-image-hover, .bm-menu, .browser-sugg, .zl-ctx, .ext-menu'

const overlaps = (a: DOMRect, b: DOMRect): boolean => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom

let labelSeq = 0

/**
 * Keeps a native page (browser.zig) glued to its placeholder `viewRef`. It is shown only while `live`
 * (its pane is the one in front), nothing is drawn over it, the window is not hidden and it is not
 * `hidden`; otherwise it is parked, and the engine throttles, then freezes it.
 */
export function usePlacedPage(viewRef: React.RefObject<HTMLDivElement | null>, label: string, live: boolean, onScreen: boolean, zoom: number, hidden: boolean): void {
  useEffect(() => {
    const el = viewRef.current
    if (!el) return
    let last = ''
    const place = (): void => {
      if (!live) {
        window.api.browser.place(label, { x: 0, y: 0, w: 0, h: 0 }, zoom, false)
        return
      }
      const r = el.getBoundingClientRect()
      const fits = r.width > 4 && r.height > 4 && document.visibilityState === 'visible' && !el.closest('.browser-tab-pane:not(.on)')
      const covered = fits && [...document.querySelectorAll(OVERLAYS)].some((o) => overlaps(o.getBoundingClientRect(), r))
      const visible = fits && !covered && !hidden
      const key = visible ? `${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.width)},${Math.round(r.height)},${zoom}` : 'off'
      if (key === last) return
      last = key
      window.api.browser.place(label, { x: r.left, y: r.top, w: r.width, h: r.height }, zoom, visible)
    }
    let frame = 0
    const soon = (): void => {
      if (!frame) frame = requestAnimationFrame(() => {
        frame = 0
        place()
      })
    }
    // parked: nothing to follow. (Every tab of every chat used to watch the whole document, so each
    // terminal redraw made all of them measure the layout.)
    if (!live) {
      // switched to another Web tab: that page is shown (on top) first, this one hides a moment
      // later — hiding first left a blank pane flashing between the two
      if (!onScreen) return place()
      const id = window.setTimeout(place, 120)
      return () => window.clearTimeout(id)
    }
    place()
    const ro = new ResizeObserver(soon)
    ro.observe(el)
    // menus / dialogs opening, panes sliding, the chat switching. Changes inside a terminal or an
    // editor (every line of output, the cursor) can't move the page or cover it: skip those.
    const mo = new MutationObserver((recs) => {
      for (const r of recs) {
        const el = r.target instanceof Element ? r.target : r.target.parentElement
        if (el && !el.closest('.xterm, .monaco-editor')) return soon()
      }
    })
    mo.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style'] })
    window.addEventListener('resize', soon)
    document.addEventListener('visibilitychange', soon)
    document.addEventListener('transitionend', soon, true)
    // slide-in animations move the placeholder without resizing it: follow it frame by frame while
    // one runs (instead of measuring every 300 ms forever), plus a slow check as a safety net
    let until = 0
    let loop = 0
    const step = (): void => {
      place()
      loop = performance.now() < until ? requestAnimationFrame(step) : 0
    }
    const follow = (e: Event): void => {
      // hover colours and fades can't move the page
      if (e instanceof TransitionEvent && COLOR_ONLY.has(e.propertyName)) return
      until = performance.now() + 700
      if (!loop) loop = requestAnimationFrame(step)
    }
    document.addEventListener('transitionrun', follow, true)
    document.addEventListener('animationstart', follow, true)
    const tick = window.setInterval(place, 1000)
    return () => {
      cancelAnimationFrame(frame)
      ro.disconnect()
      mo.disconnect()
      window.removeEventListener('resize', soon)
      document.removeEventListener('visibilitychange', soon)
      document.removeEventListener('transitionend', soon, true)
      window.clearInterval(tick)
      cancelAnimationFrame(loop)
      document.removeEventListener('transitionrun', follow, true)
      document.removeEventListener('animationstart', follow, true)
    }
  }, [viewRef, live, onScreen, label, zoom, hidden])
}

export function BrowserTab({ chatKey, tabId, active, onScreen }: { chatKey: string; tabId: string; active: boolean; onScreen: boolean }): React.JSX.Element {
  const t = useT()
  const viewRef = useRef<HTMLDivElement>(null)
  const stageRef = useRef<HTMLDivElement>(null)
  const url = useStore((s) => s.browsers[chatKey]?.tabs.find((t) => t.id === tabId)?.url ?? HOME_URL)
  // the native page this tab owns (labels: letters, digits, - _ only)
  const [label] = useState(() => `web-${++labelSeq}-${tabId}`.replace(/[^\w-]/g, '_'))
  // first URL only: later navigation happens inside the page
  const [initial] = useState(url)
  const [address, setAddress] = useState(display(url))
  const shown = useRef(url)
  const [loading, setLoading] = useState(true)
  const [nav, setNav] = useState({ back: false, fwd: false })
  const [deviceKey, setDeviceKey] = useState(savedDevice)
  const device = DEVICES.find((d) => d.key === deviceKey) ?? DEVICES[0]
  const [initialUa] = useState(device.ua)
  const [box, setBox] = useState<{ w: number; h: number; zoom: number } | null>(null)
  const addressRef = useRef<HTMLInputElement>(null)
  // blank tab: the native page is hidden and a start page with a random photo shows instead
  const [home, setHome] = useState(url === HOME_URL)

  /*
   * A blank tab puts the cursor in the address bar — without scrolling: focusing an input inside the
   * sliding, overflow-hidden deck made the whole page jump. Not when a chat terminal has the cursor
   * (a new chat opened while on Web keeps typing into the chat).
   */
  useEffect(() => {
    if (!active || display(url)) return
    const el = addressRef.current
    if (!el || el.closest('.center-pane:not(.on)')) return
    const cur = document.activeElement
    if (cur && cur !== document.body && cur.closest('.xterm')) return
    el.focus({ preventScroll: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active])

  // the native page lives as long as this tab
  useEffect(() => {
    void window.api.browser.open(label, chatKey, initial, initialUa)
    return () => window.api.browser.close(label)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [label])

  // address bar / buttons follow the page
  useEffect(
    () =>
      window.api.browser.onNav((l, n) => {
        if (l !== label) return
        setLoading(n.loading)
        setNav({ back: n.back, fwd: n.fwd })
        if (!n.url) return
        if (!n.loading || n.url !== HOME_URL) setHome(n.url === HOME_URL)
        if (n.url !== shown.current && !n.loading) window.api.browser.visit(n.url)
        if (n.title) window.api.browser.title(n.url, n.title)
        if (document.activeElement !== addressRef.current) setAddress(display(n.url))
        shown.current = n.url
        setBrowserUrl(chatKey, n.url, tabId, n.title || undefined)
      }),
    [label, chatKey, tabId]
  )

  // lets this chat's Claude drive the page (browser_* MCP tools): always the tab you're looking at
  useEffect(() => {
    if (active) window.api.browser.setActive(chatKey, label)
  }, [active, chatKey, label])

  // openBrowser(url) from elsewhere in the app: navigate there
  useEffect(() => {
    if (url !== shown.current) {
      shown.current = url
      setAddress(display(url))
      setHome(url === HOME_URL)
      void window.api.browser.navigate(label, url).catch(() => {})
    }
  }, [url, label])

  /*
   * Emulated screen: the page lays out at the device's size (e.g. 1920×1080), then is zoomed out
   * to fit this pane. Zoom (not a CSS transform) keeps clicks and scrolling exact.
   */
  useEffect(() => {
    const stage = stageRef.current
    if (!stage) return
    const fit = (): void => {
      const W = stage.clientWidth
      const H = stage.clientHeight
      if (W < 20 || H < 20) return // hidden tab
      if (!device.w || !device.h) return setBox(null)
      const zoom = Math.min(1, (W - 16) / device.w, (H - 16) / device.h)
      setBox({ w: Math.floor(device.w * zoom), h: Math.floor(device.h * zoom), zoom })
    }
    fit()
    const ro = new ResizeObserver(fit)
    ro.observe(stage)
    return () => ro.disconnect()
  }, [device.w, device.h])

  /*
   * Keep the native page glued to its placeholder. It is shown only while this is the open tab of
   * the chat on screen, the Web view is in front, nothing is drawn over it and the window is not
   * hidden; otherwise it is parked — and the engine throttles, then freezes it.
   */
  const zoom = box?.zoom ?? 1
  // the open tab of the chat on screen, with the Web view in front: only that page is tracked live
  const live = active && onScreen
  usePlacedPage(viewRef, label, live, onScreen, zoom, home)

  const pickDevice = (key: string): void => {
    const next = DEVICES.find((d) => d.key === key) ?? DEVICES[0]
    try {
      localStorage.setItem(DEVICE_KEY, key)
    } catch {
      /* per-viewer convenience only */
    }
    // phone/tablet ↔ desktop changes the browser identity; the page reloads to pick it up
    if ((next.ua ?? '') !== (device.ua ?? '')) void window.api.browser.setUserAgent(label, next.ua ?? null)
    setDeviceKey(key)
  }

  const adBlock = useStore((s) => s.settings?.adBlock ?? true)
  const [blocker, setBlocker] = useState('')
  useEffect(() => {
    void window.api.browser.adblockStatus().then(setBlocker)
    return window.api.browser.onAdblockStatus(setBlocker)
  }, [])
  const toggleAdBlock = async (): Promise<void> => {
    const settings = await window.api.app.setSettings({ adBlock: !adBlock }).catch(() => null)
    if (settings) useStore.setState({ settings })
    // the page now loaded was fetched under the old rule
    window.api.browser.reload(label)
  }

  const [clearing, setClearing] = useState(false)
  const clearCache = async (): Promise<void> => {
    setClearing(true)
    try {
      await window.api.app.clearBrowserCache()
      window.api.browser.reload(label, true)
    } finally {
      setClearing(false)
    }
  }

  const go = (to = toUrl(address)): void => {
    typed.current = '' // a suggestion request still on its way must not reopen the list over the page
    setAddress(to)
    setSugg([])
    setHome(to === HOME_URL)
    shown.current = to
    void window.api.browser.navigate(label, to).catch(() => {})
  }

  // address-bar suggestions from bookmarks + history
  const [sugg, setSugg] = useState<WebSuggestion[]>([])
  const [pick, setPick] = useState(-1)
  const typed = useRef('')
  const onType = (v: string): void => {
    setAddress(v)
    setPick(-1)
    typed.current = v
    if (!v.trim()) return setSugg([])
    void window.api.browser.suggest(v).then((list) => {
      if (typed.current === v) setSugg(list)
    })
  }

  return (
    <div className="browser-tab">
      <div className="browser-bar">
        <button className="icon-btn" title={t('Back', 'Lùi')} disabled={!nav.back} onClick={() => window.api.browser.back(label)}>
          <ArrowLeft size={15} />
        </button>
        <button className="icon-btn" title={t('Forward', 'Tiến')} disabled={!nav.fwd} onClick={() => window.api.browser.forward(label)}>
          <ArrowRight size={15} />
        </button>
        <button className="icon-btn" title={loading ? t('Stop', 'Dừng') : t('Reload', 'Tải lại')} onClick={() => (loading ? window.api.browser.stop(label) : window.api.browser.reload(label))}>
          {loading ? <X size={15} /> : <RotateCw size={14} />}
        </button>
        <div className="browser-address-wrap">
          <input
            ref={addressRef}
            className="browser-address"
            value={address}
            spellCheck={false}
            placeholder={t('Search or type a URL', 'Tìm kiếm hoặc nhập URL')}
            onChange={(e) => onType(e.target.value)}
            onFocus={(e) => e.currentTarget.select()}
            onBlur={() => {
              typed.current = ''
              setTimeout(() => setSugg([]), 120)
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter') go(pick >= 0 && sugg[pick] ? sugg[pick].url : undefined)
              else if (e.key === 'Escape') {
                typed.current = ''
                setSugg([])
              }
              else if (e.key === 'ArrowDown' && sugg.length) {
                e.preventDefault()
                setPick((i) => (i + 1) % sugg.length)
              } else if (e.key === 'ArrowUp' && sugg.length) {
                e.preventDefault()
                setPick((i) => (i <= 0 ? sugg.length - 1 : i - 1))
              }
            }}
          />
          {sugg.length > 0 && (
            <div className="browser-sugg">
              {sugg.map((x, i) => (
                <button key={x.url} className={i === pick ? 'on' : ''} onMouseDown={(e) => e.preventDefault()} onClick={() => go(x.url)}>
                  <span className="bs-title">
                    {x.bookmark && <Star size={11} />}
                    {x.title || x.url}
                  </span>
                  <span className="bs-url">{x.url}</span>
                </button>
              ))}
            </div>
          )}
        </div>
        <div className="device-seg" role="radiogroup" aria-label={t('Screen size', 'Kích thước màn hình')}>
          <SlidePill />
          {DEVICES.map((d) => (
            <button key={d.key} role="radio" aria-checked={d.key === deviceKey} className={d.key === deviceKey ? 'on' : ''} title={d.label(t)} onClick={() => pickDevice(d.key)}>
              {d.icon}
            </button>
          ))}
        </div>
        {box && <span className="device-zoom" title={t('Zoomed out to fit', 'Đã thu nhỏ cho vừa khung')}>{Math.round(box.zoom * 100)}%</span>}
        {window.api.platform === 'win32' && (
          <button
            className={`icon-btn${adBlock ? ' adblock-on' : ''}`}
            title={t(`Ad blocking ${adBlock ? 'on' : 'off'} — ${blocker}. Click to turn it ${adBlock ? 'off' : 'on'} (reloads)`, `Chặn quảng cáo đang ${adBlock ? 'bật' : 'tắt'} — ${blocker}. Bấm để ${adBlock ? 'tắt' : 'bật'} (tải lại trang)`)}
            onClick={() => void toggleAdBlock()}
          >
            {adBlock ? <ShieldCheck size={14} /> : <ShieldOff size={14} />}
          </button>
        )}
        {window.api.platform === 'win32' && (
          <ExtensionsButton
            adBlock={adBlock}
            onToggleAdBlock={() => void toggleAdBlock()}
            onOpen={(url) => newBrowserTab(chatKey, url)}
            onChanged={() => window.api.browser.reload(label)}
          />
        )}
        <button className="icon-btn" title={t('Clear cache & reload (keeps logins)', 'Xoá bộ nhớ đệm và tải lại (giữ đăng nhập)')} disabled={clearing} onClick={clearCache}>
          <Eraser size={14} />
        </button>
        <button className="icon-btn" title={t('Open in your browser', 'Mở trong trình duyệt của bạn')} disabled={!address} onClick={() => window.api.app.openExternal(address)}>
          <ExternalLink size={14} />
        </button>
      </div>
      <BookmarkBar onOpen={(u) => go(u)} />
      <div className={`browser-stage${box ? ' emulated' : ''}`} ref={stageRef}>
        {/* placeholder: the native page is laid over exactly this box */}
        <div ref={viewRef} className="browser-view" style={box ? { width: box.w, height: box.h, flex: 'none' } : undefined} />
        {home && <StartPage onGo={(text) => go(toUrl(text))} />}
      </div>
    </div>
  )
}

/* ---------------- start page ---------------- */

/** A random landscape photo (Unsplash pictures via picsum.photos, no key needed). */
const randomPhoto = (): string => `https://picsum.photos/seed/${Math.random().toString(36).slice(2, 10)}/1920/1080`

/** Blank tab: a new random photo every time, a clock and a search box — like a browser's new tab page. */
function StartPage({ onGo }: { onGo: (text: string) => void }): React.JSX.Element {
  const t = useT()
  const [photo, setPhoto] = useState(randomPhoto)
  const [ready, setReady] = useState<string | null>(null)
  const [now, setNow] = useState(() => new Date())
  const [q, setQ] = useState('')

  // show the photo only once it has loaded, so it fades in instead of painting line by line
  useEffect(() => {
    const img = new Image()
    // a shuffle before this one loaded: the older photo must not land last
    img.onload = () => setReady(photo)
    img.src = photo
    return () => {
      img.onload = null
      img.src = ''
    }
  }, [photo])

  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 10000)
    return () => clearInterval(timer)
  }, [])

  return (
    <div className="start-page">
      <div className={`start-photo${ready ? ' on' : ''}`} style={ready ? { backgroundImage: `url("${ready}")` } : undefined} />
      <div className="start-content">
        <div className="start-clock">{now.toLocaleTimeString(t('en-US', 'vi-VN'), { hour: '2-digit', minute: '2-digit' })}</div>
        <div className="start-date">{now.toLocaleDateString(t('en-US', 'vi-VN'), { weekday: 'long', day: 'numeric', month: 'long' })}</div>
        <form
          className="start-search"
          onSubmit={(e) => {
            e.preventDefault()
            if (q.trim()) onGo(q)
          }}
        >
          <Search size={16} />
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('Search Google or type a URL', 'Tìm trên Google hoặc nhập URL')} spellCheck={false} />
        </form>
      </div>
      <button className="start-shuffle" title={t('Another photo', 'Ảnh khác')} onClick={() => setPhoto(randomPhoto())}>
        <Shuffle size={14} />
      </button>
    </div>
  )
}
