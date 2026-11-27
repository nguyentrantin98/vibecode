import { useEffect, useState } from 'react'

/**
 * One tooltip for the whole app: buttons are icons only, their `title` shows here on hover
 * (quicker and quieter than the system tooltip). The `title` is taken off while it shows, so the
 * system one doesn't pop up too, and put back on leave.
 */
export function TooltipHost(): React.JSX.Element | null {
  const [tip, setTip] = useState<{ text: string; x: number; top: number; bottom: number } | null>(null)

  useEffect(() => {
    let el: HTMLElement | null = null
    let text = ''
    let timer: ReturnType<typeof setTimeout> | undefined
    let lastHide = 0

    const hide = (): void => {
      clearTimeout(timer)
      // React may have set a new title meanwhile: only put ours back when there is none
      if (el && !el.hasAttribute('title')) el.setAttribute('title', text)
      if (el) lastHide = Date.now()
      el = null
      setTip(null)
    }
    const over = (e: PointerEvent): void => {
      // still inside the one showing (its title is off, so closest() would find an outer one)
      if (el?.contains(e.target as Node)) return
      const target = (e.target as Element | null)?.closest?.('[title]') as HTMLElement | null
      if (!target || target === el) return
      const t = target.getAttribute('title') ?? ''
      if (!t.trim()) return
      hide()
      el = target
      text = t
      target.removeAttribute('title')
      // moving from one button to the next: no wait
      const wait = Date.now() - lastHide < 400 ? 0 : 450
      timer = setTimeout(() => {
        if (el !== target || !target.isConnected) return
        const r = target.getBoundingClientRect()
        setTip({ text: t, x: r.left + r.width / 2, top: r.top, bottom: r.bottom })
      }, wait)
    }
    const out = (e: PointerEvent): void => {
      if (el && !el.contains(e.relatedTarget as Node | null)) hide()
    }
    document.addEventListener('pointerover', over, true)
    document.addEventListener('pointerout', out, true)
    window.addEventListener('pointerdown', hide, true)
    window.addEventListener('keydown', hide, true)
    window.addEventListener('wheel', hide, true)
    window.addEventListener('blur', hide)
    return () => {
      hide()
      document.removeEventListener('pointerover', over, true)
      document.removeEventListener('pointerout', out, true)
      window.removeEventListener('pointerdown', hide, true)
      window.removeEventListener('keydown', hide, true)
      window.removeEventListener('wheel', hide, true)
      window.removeEventListener('blur', hide)
    }
  }, [])

  if (!tip) return null
  return (
    <div
      className="tooltip"
      ref={(n) => {
        // under the button, above it when there is no room below; always inside the window
        if (!n) return
        const w = n.offsetWidth
        const h = n.offsetHeight
        n.style.left = `${Math.max(6, Math.min(tip.x - w / 2, window.innerWidth - w - 6))}px`
        n.style.top = `${tip.bottom + 6 + h <= window.innerHeight - 6 ? tip.bottom + 6 : Math.max(6, tip.top - 6 - h)}px`
      }}
    >
      {tip.text}
    </div>
  )
}
