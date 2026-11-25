import { useEffect, useRef, useState } from 'react'
import { Fan, Loader2, Snowflake, Thermometer } from 'lucide-react'
import type { FanProfile, ThermalInfo } from '../../../shared/types'
import { useT, type T } from '../i18n'

function severity(c: number): 'normal' | 'warning' | 'critical' {
  return c >= 85 ? 'critical' : c >= 70 ? 'warning' : 'normal'
}

function verdict(c: number, t: T): string {
  return c >= 85 ? t('Very hot', 'Rất nóng') : c >= 70 ? t('Hot', 'Nóng') : c >= 55 ? t('Warm', 'Ấm') : t('Cool', 'Mát')
}

/**
 * Status-bar temperature (the hottest ACPI thermal zone), refreshed every 5 seconds. Clicking it
 * opens the cooling panel: ASUS fan profile, fans-first cooling policy and CPU turbo boost.
 */
export function TempMeter(): React.JSX.Element | null {
  const [info, setInfo] = useState<ThermalInfo | null>(null)
  const [open, setOpen] = useState(false)
  const btn = useRef<HTMLButtonElement>(null)
  const t = useT()

  useEffect(() => {
    let live = true
    const load = (): void => {
      window.api.claude.thermal?.().then((i) => live && setInfo(i)).catch(() => {})
    }
    load()
    const timer = setInterval(load, open ? 2000 : 5000)
    return () => {
      live = false
      clearInterval(timer)
    }
  }, [open])

  // shown when the machine has something to show: a temperature, or a cooling setting it supports
  if (!info || (info.celsius == null && !hasCooling(info))) return null
  const c = info.celsius == null ? null : Math.round(info.celsius)
  return (
    <>
      <button
        ref={btn}
        className={`usage-meter temp-meter${c == null ? '' : ` sev-${severity(c)}`}`}
        title={c == null ? t('Cooling', 'Làm mát') : t(`Temperature: ${c}°C · click for cooling`, `Nhiệt độ: ${c}°C · bấm để chỉnh làm mát`)}
        onClick={() => setOpen((o) => !o)}
      >
        {c == null ? <Fan size={12} /> : <Thermometer size={12} />}
        {c != null && (
          <span className="usage-bar">
            <span style={{ width: `${Math.min(100, Math.max(0, ((c - 30) / 70) * 100))}%` }} />
          </span>
        )}
        <span className="usage-pct">{c == null ? t('Cooling', 'Làm mát') : `${c}°C`}</span>
      </button>
      {open && <CoolingPanel info={info} onInfo={setInfo} anchor={btn.current} onClose={() => setOpen(false)} />}
    </>
  )
}

/** the machine can change at least one cooling setting (Windows power plan or ASUS firmware) */
function hasCooling(i: ThermalInfo): boolean {
  return i.asus || i.activeCooling !== null || i.turboOff !== null
}

/** A panel that opens above a status-bar item; closes on a click outside it or Escape. */
export function StatusPopover({ anchor, onClose, width, children }: { anchor: HTMLElement | null; onClose: () => void; width: number; children: React.ReactNode }): React.JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node) && !anchor?.contains(e.target as Node)) onClose()
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('mousedown', close, true)
    window.addEventListener('keydown', esc, true)
    return () => {
      window.removeEventListener('mousedown', close, true)
      window.removeEventListener('keydown', esc, true)
    }
  }, [anchor, onClose])
  const rect = anchor?.getBoundingClientRect()
  const left = rect ? Math.max(8, Math.min(window.innerWidth - width - 8, rect.left + rect.width / 2 - width / 2)) : 8
  const bottom = rect ? window.innerHeight - rect.top + 6 : 30
  return (
    <div ref={ref} className="menu temp-pop" style={{ left, bottom, width }}>
      {children}
    </div>
  )
}

function CoolingPanel({ info, onInfo, anchor, onClose }: { info: ThermalInfo; onInfo: (i: ThermalInfo) => void; anchor: HTMLElement | null; onClose: () => void }): React.JSX.Element {
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const t = useT()

  const run = async (key: string, job: () => Promise<ThermalInfo | null>): Promise<void> => {
    setBusy(key)
    setError(null)
    try {
      const next = await job()
      if (next) onInfo(next)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(null)
    }
  }
  const setFan = (p: FanProfile): Promise<void> => run(`fan-${p}`, () => window.api.claude.setFanProfile(p))
  const setCooling = (o: { activeCooling?: boolean; turboOff?: boolean }): Promise<void> => run(Object.keys(o).join(), () => window.api.claude.setCooling(o))
  const maxCooling = (): Promise<void> =>
    run('max', async () => {
      let next = await window.api.claude.setCooling({ activeCooling: true, turboOff: true })
      if (info.asus) next = await window.api.claude.setFanProfile('full')
      return next
    })

  const c = info.celsius == null ? null : Math.round(info.celsius)
  const windows = info.activeCooling !== null || info.turboOff !== null
  const profiles: { id: FanProfile; label: string }[] = [
    { id: 'silent', label: t('Quiet', 'Êm') },
    { id: 'standard', label: t('Standard', 'Tiêu chuẩn') },
    { id: 'performance', label: t('Performance', 'Hiệu năng') }
  ]
  const spin = (key: string): React.JSX.Element | null => (busy === key ? <Loader2 size={12} className="spin" /> : null)

  return (
    <StatusPopover anchor={anchor} onClose={onClose} width={320}>
      <div className={`temp-head${c == null ? '' : ` sev-${severity(c)}`}`}>
        {c == null ? <Fan size={20} /> : <Thermometer size={20} />}
        <div>
          <div className="temp-big">{c == null ? t('Cooling', 'Làm mát') : `${c}°C`}</div>
          <div className="temp-sub">{c == null ? t('No temperature sensor reported', 'Máy không báo nhiệt độ') : verdict(c, t)}</div>
        </div>
        {hasCooling(info) && <button className="btn btn-primary temp-max" disabled={busy !== null} onClick={() => void maxCooling()} title={t('Turbo off, fans first' + (info.asus ? ', fan at 100%' : ''), 'Tắt Turbo, ưu tiên quạt' + (info.asus ? ', quạt 100%' : ''))}>
          {spin('max') ?? <Snowflake size={13} />}
          {t('Max cooling', 'Làm mát tối đa')}
        </button>}
      </div>
      {info.zones.length > 1 && (
        <div className="temp-zones">
          {info.zones.map((z) => (
            <span key={z.name}>
              {z.name.replace(/^\\?_tz\./i, '').toUpperCase()} {Math.round(z.celsius)}°C
            </span>
          ))}
        </div>
      )}

      {info.asus && (
        <>
          <div className="menu-sep">
            <Fan size={11} /> {t('ASUS fan', 'Quạt ASUS')}
            {info.cpuFanRpm != null && info.cpuFanRpm > 0 && <span className="temp-rpm">{info.cpuFanRpm} RPM</span>}
          </div>
          <div className="temp-seg">
            {profiles.map((p) => (
              <button key={p.id} className={info.fanProfile === p.id ? 'on' : ''} disabled={busy !== null} onClick={() => void setFan(p.id)}>
                {spin(`fan-${p.id}`)}
                {p.label}
              </button>
            ))}
          </div>
          <Toggle
            on={info.fanFull}
            disabled={busy !== null}
            busy={busy === 'fan-full' || busy === 'fan-auto'}
            label={t('Fan at 100%', 'Quạt tối đa 100%')}
            sub={t('Full speed until turned off (loud)', 'Quay hết tốc độ cho tới khi tắt (khá ồn)')}
            onChange={(v) => void run(v ? 'fan-full' : 'fan-auto', () => window.api.claude.setFanProfile(v ? 'full' : 'auto'))}
          />
          <div className="temp-note">{t('Windows asks for admin permission each change.', 'Mỗi lần đổi, Windows sẽ hỏi quyền quản trị.')}</div>
        </>
      )}

      {windows && <div className="menu-sep">{t('Windows cooling', 'Làm mát Windows')}</div>}
      {info.activeCooling !== null && (
        <Toggle
          on={info.activeCooling}
          disabled={busy !== null}
          busy={busy === 'activeCooling'}
          label={t('Fans first', 'Ưu tiên quạt')}
          sub={t('Speed up the fans before slowing the CPU', 'Tăng tốc quạt trước khi hạ xung CPU')}
          onChange={(v) => void setCooling({ activeCooling: v })}
        />
      )}
      {info.turboOff !== null && (
        <Toggle
          on={info.turboOff}
          disabled={busy !== null}
          busy={busy === 'turboOff'}
          label={t('Turbo Boost off', 'Tắt Turbo Boost')}
          sub={t('Much cooler and quieter, slower under heavy load', 'Mát và êm hơn nhiều, chậm hơn khi tải nặng')}
          onChange={(v) => void setCooling({ turboOff: v })}
        />
      )}
      {error && <div className="temp-error">{error}</div>}
    </StatusPopover>
  )
}

function Toggle({ on, disabled, busy, label, sub, onChange }: { on: boolean; disabled: boolean; busy: boolean; label: string; sub: string; onChange: (v: boolean) => void }): React.JSX.Element {
  return (
    <button className="menu-item temp-toggle" disabled={disabled} onClick={() => onChange(!on)}>
      <span className="temp-toggle-text">
        <span className="menu-item-main">{label}</span>
        <span className="temp-toggle-sub">{sub}</span>
      </span>
      {busy ? <Loader2 size={13} className="spin" /> : <span className={`temp-switch${on ? ' on' : ''}`} />}
    </button>
  )
}
