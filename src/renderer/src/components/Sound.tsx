import { useEffect, useRef, useState } from 'react'
import { AudioLines, Loader2, ShieldCheck, Trash2 } from 'lucide-react'
import type { SoundInfo } from '../../../shared/types'
import { useT, type T } from '../i18n'
import { StatusPopover } from './Thermal'

/** dB per band: 31 62 125 250 500 1k 2k 4k 8k 16k */
const PRESETS: { id: string; label: (t: T) => string; bands: number[] }[] = [
  { id: 'flat', label: (t) => t('Flat', 'Phẳng'), bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
  { id: 'less-bass', label: (t) => t('Less bass', 'Giảm bass'), bands: [-9, -7, -5, -3, -1, 0, 0, 0, 0, 0] },
  { id: 'laptop', label: (t) => t('Laptop speakers', 'Loa laptop'), bands: [-12, -9, -5, -2, 0, 1, 2, 2.5, 1.5, 0] },
  { id: 'voice', label: (t) => t('Clear voice', 'Rõ giọng'), bands: [-6, -5, -3, -1, 0, 2, 3.5, 3, 1, 0] },
  { id: 'bright', label: (t) => t('Bright & detailed', 'Sáng, chi tiết'), bands: [-3, -2, -1, 0, 0, 1, 2, 3, 4, 4] },
  { id: 'warm', label: (t) => t('Warm', 'Ấm'), bands: [2, 2, 1.5, 1, 0, 0, -1, -1.5, -2, -2] },
  { id: 'more-bass', label: (t) => t('More bass', 'Tăng bass'), bands: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0] }
]

const freqLabel = (f: number): string => (f >= 1000 ? `${f / 1000}k` : String(f))

/** Status-bar Sound item: a whole-machine equalizer through VIBE CODE's own audio filter. */
export function SoundMeter(): React.JSX.Element | null {
  const [info, setInfo] = useState<SoundInfo | null>(null)
  const [open, setOpen] = useState(false)
  const btn = useRef<HTMLButtonElement>(null)
  const t = useT()

  // refreshed every 30 s too, so it appears when headphones that can take the filter are plugged in
  useEffect(() => {
    let live = true
    const load = (): void => void window.api.claude.sound?.().then((i) => live && setInfo(i), () => {})
    load()
    const timer = setInterval(load, 30000)
    return () => {
      live = false
      clearInterval(timer)
    }
  }, [open])

  if (!info?.supported) return null
  const preset = PRESETS.find((p) => p.id === info.preset)
  const label = !info.installed || !info.enabled ? 'EQ' : preset ? preset.label(t) : t('Custom', 'Tùy chỉnh')
  return (
    <>
      <button ref={btn} className={`usage-meter temp-meter${info.enabled ? ' sound-on' : ''}`} title={t('Sound: equalizer for the whole computer', 'Âm thanh: EQ cho cả máy')} onClick={() => setOpen((o) => !o)}>
        <AudioLines size={12} />
        <span className="usage-pct">{label}</span>
      </button>
      {open && <SoundPanel info={info} onInfo={setInfo} anchor={btn.current} onClose={() => setOpen(false)} />}
    </>
  )
}

function SoundPanel({ info, onInfo, anchor, onClose }: { info: SoundInfo; onInfo: (i: SoundInfo) => void; anchor: HTMLElement | null; onClose: () => void }): React.JSX.Element {
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState<'install' | 'remove' | null>(null)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const t = useT()

  // a slider drag writes the filter's eq.txt at most every 150 ms
  const save = (next: { enabled: boolean; preset: string; bands: number[] }, now = false): void => {
    onInfo({ ...info, ...next })
    if (timer.current) clearTimeout(timer.current)
    const write = (): void => {
      setError(null)
      window.api.claude.setSound(next).then(onInfo, (e) => setError(e instanceof Error ? e.message : String(e)))
    }
    if (now) write()
    else timer.current = setTimeout(write, 150)
  }
  useEffect(() => () => void (timer.current && clearTimeout(timer.current)), [])

  const admin = (what: 'install' | 'remove'): void => {
    setBusy(what)
    setError(null)
    ;(what === 'install' ? window.api.claude.soundInstall() : window.api.claude.soundRemove())
      .then(onInfo, (e) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setBusy(null))
  }

  if (!info.installed)
    return (
      <StatusPopover anchor={anchor} onClose={onClose} width={340}>
        <div className="temp-head">
          <AudioLines size={20} />
          <div>
            <div className="sound-title">{t('Sound equalizer', 'EQ âm thanh')}</div>
            <div className="temp-sub">{t("VIBE CODE's own audio filter, for every app", 'Bộ lọc âm thanh riêng của VIBE CODE, cho mọi ứng dụng')}</div>
          </div>
        </div>
        <ul className="sound-steps">
          <li>{t('Works on devices without their own driver effects: HDMI / monitor speakers, many USB and Bluetooth headphones. Not yet on Realtek laptop speakers.', 'Dùng được cho thiết bị không có hiệu ứng riêng của driver: loa màn hình HDMI, nhiều tai nghe USB/Bluetooth. Loa laptop Realtek chưa hỗ trợ.')}</li>
          <li>{t('Windows asks for admin once; sound pauses for a second while audio restarts.', 'Windows hỏi quyền quản trị một lần; âm thanh ngắt khoảng 1 giây khi khởi động lại dịch vụ âm thanh.')}</li>
          <li>{t('Remove it any time from this panel.', 'Gỡ lúc nào cũng được ngay trong bảng này.')}</li>
        </ul>
        <div className="sound-actions">
          <button className="btn btn-primary" onClick={() => admin('install')} disabled={busy !== null}>
            {busy === 'install' ? <Loader2 size={13} className="spin" /> : <ShieldCheck size={13} />}
            {t('Install the equalizer', 'Cài bộ chỉnh âm')}
          </button>
        </div>
        {error && <div className="temp-error">{error}</div>}
      </StatusPopover>
    )

  const setBand = (i: number, v: number): void => {
    const bands = info.bands.map((b, j) => (j === i ? v : b))
    const match = PRESETS.find((p) => p.bands.every((b, j) => b === bands[j]))
    save({ enabled: true, preset: match?.id ?? 'custom', bands })
  }

  return (
    <StatusPopover anchor={anchor} onClose={onClose} width={360}>
      <button className="menu-item temp-toggle" onClick={() => save({ enabled: !info.enabled, preset: info.preset, bands: info.bands }, true)}>
        <span className="temp-toggle-text">
          <span className="menu-item-main">{t('Equalizer', 'Bộ chỉnh âm (EQ)')}</span>
          <span className="temp-toggle-sub">{t('For every app on this computer', 'Cho mọi ứng dụng trên máy')}</span>
        </span>
        <span className={`temp-switch${info.enabled ? ' on' : ''}`} />
      </button>

      <div className="menu-sep">{t('Presets', 'Kiểu âm')}</div>
      <div className="sound-presets">
        {PRESETS.map((p) => (
          <button key={p.id} className={info.enabled && info.preset === p.id ? 'on' : ''} onClick={() => save({ enabled: true, preset: p.id, bands: p.bands }, true)}>
            {p.label(t)}
          </button>
        ))}
      </div>

      <div className="menu-sep">
        {t('Bands', 'Dải tần')}
        <span className="temp-rpm">{info.preset === 'custom' && info.enabled ? t('Custom', 'Tùy chỉnh') : ''}</span>
      </div>
      <div className={`sound-eq${info.enabled ? '' : ' off'}`}>
        {info.freqs.map((f, i) => (
          <label key={f} className="sound-band" title={`${freqLabel(f)} Hz: ${info.bands[i] > 0 ? '+' : ''}${info.bands[i]} dB`}>
            <span className="sound-db">{info.bands[i] > 0 ? '+' : ''}{info.bands[i]}</span>
            <input type="range" min={-12} max={12} step={0.5} value={info.bands[i]} onChange={(e) => setBand(i, Number(e.target.value))} onDoubleClick={() => setBand(i, 0)} />
            <span className="sound-freq">{freqLabel(f)}</span>
          </label>
        ))}
      </div>
      <div className="temp-note">{t('Bass: 31–250 Hz · voice: 1k–4k · treble: 8k–16k. Double-click a slider to reset it.', 'Bass: 31–250 Hz · giọng: 1k–4k · treble: 8k–16k. Bấm đúp thanh trượt để về 0.')}</div>

      <div className="temp-note sound-devices">
        <span className={`sound-dot${info.running ? ' on' : ''}`} />
        {info.running ? t('Working', 'Đang hoạt động') : t('Waiting for sound', 'Chờ có âm thanh')}
        {info.devices.length > 0 && <> · {info.devices.join(', ')}</>}
      </div>
      {info.skipped.length > 0 && <div className="temp-note">{t('Not on', 'Không áp dụng cho')}: {info.skipped.join(', ')}</div>}
      <div className="sound-actions">
        <button className="btn" onClick={() => admin('install')} disabled={busy !== null} title={t('Run the install again, e.g. after pairing new headphones', 'Cài lại, ví dụ sau khi kết nối tai nghe mới')}>
          {busy === 'install' ? <Loader2 size={13} className="spin" /> : <ShieldCheck size={13} />}
          {t('Add new devices', 'Thêm thiết bị mới')}
        </button>
        <button className="btn" onClick={() => admin('remove')} disabled={busy !== null}>
          {busy === 'remove' ? <Loader2 size={13} className="spin" /> : <Trash2 size={13} />}
          {t('Remove', 'Gỡ bộ lọc')}
        </button>
      </div>
      {error && <div className="temp-error">{error}</div>}
    </StatusPopover>
  )
}
