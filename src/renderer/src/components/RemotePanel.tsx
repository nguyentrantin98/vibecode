import { useEffect, useRef, useState } from 'react'
import { Smartphone, Trash2 } from 'lucide-react'
import type { RemoteState } from '../../../shared/types'
import { useT } from '../i18n'
import { qrMatrix } from '../qr'

/** The Internet address: its QR code (with the PIN in it while one is shown: scanning pairs at once), or where it is at. */
function Tunnel({ st, pinLive }: { st: RemoteState; pinLive: boolean }): React.JSX.Element {
  const t = useT()
  const [copied, setCopied] = useState(false)
  if (st.tunnelPhase === 'download')
    return <div className="remote-sub">{t('Downloading cloudflared (once)…', 'Đang tải cloudflared (một lần)…') + ` ${Math.floor((st.tunnelDone / st.tunnelTotal) * 100)}%`}</div>
  if (st.tunnelPhase === 'failed')
    return <div className="remote-sub remote-bad">{t('Could not open the tunnel: ', 'Không mở được đường hầm: ') + st.tunnelError + t(' — trying again shortly', ' — sẽ thử lại sau ít giây')}</div>
  if (st.tunnelPhase !== 'up' || !st.tunnelUrl)
    return <div className="remote-sub">{st.tunnelUrl ? t('Connection to Cloudflare lost, reconnecting…', 'Mất kết nối tới Cloudflare, đang nối lại…') : t('Opening a Cloudflare tunnel…', 'Đang mở đường hầm Cloudflare…')}</div>
  const link = st.tunnelUrl + '/' + (pinLive && st.pin ? `#pair=${st.pin}` : '')
  const m = qrMatrix(link)
  const n = m.length + 8
  let d = ''
  m.forEach((row, y) => row.forEach((dark, x) => dark && (d += `M${x + 4} ${y + 4}h1v1h-1z`)))
  return (
    <>
      <svg className="remote-qr" viewBox={`0 0 ${n} ${n}`} shapeRendering="crispEdges">
        <rect width={n} height={n} fill="#fff" />
        <path d={d} fill="#000" />
      </svg>
      <div className="remote-sub">
        {pinLive
          ? t('Scan with the phone camera: it opens and pairs by itself.', 'Quét bằng camera điện thoại: mở và ghép nối luôn.')
          : t('Scan with the phone camera, then pair with a PIN. Paired phones get this link by themselves.', 'Quét bằng camera điện thoại rồi ghép nối bằng PIN. Điện thoại đã ghép tự nhận link này.')}
      </div>
      <button
        className="remote-url remote-link"
        title={t('Copy', 'Sao chép')}
        onClick={() =>
          void navigator.clipboard.writeText(st.tunnelUrl!).then(() => {
            setCopied(true)
            setTimeout(() => setCopied(false), 1500)
          })
        }
      >
        {copied ? t('Copied', 'Đã sao chép') : st.tunnelUrl}
      </button>
      <div className="remote-sub">
        {t('The link stays while this PC is on; it changes after a restart.', 'Link giữ nguyên khi máy còn bật; đổi sau khi khởi động lại máy.')}
      </div>
    </>
  )
}

/** Status-bar phone button: turn the phone remote on, pair a phone with a PIN, remove paired phones. */
export function RemoteButton(): React.JSX.Element {
  const [open, setOpen] = useState(false)
  const [st, setSt] = useState<RemoteState | null>(null)
  const [now, setNow] = useState(Date.now())
  const ref = useRef<HTMLDivElement>(null)
  const t = useT()

  useEffect(() => {
    const load = (): void => void window.api.remote.state().then(setSt, () => {})
    load()
    return window.api.remote.onChanged(load)
  }, [])

  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setOpen(false)
    }
    // the PIN's countdown
    const tick = setInterval(() => setNow(Date.now()), 1000)
    window.addEventListener('mousedown', close, true)
    window.addEventListener('keydown', esc, true)
    return () => {
      clearInterval(tick)
      window.removeEventListener('mousedown', close, true)
      window.removeEventListener('keydown', esc, true)
    }
  }, [open])

  const online = st?.devices.filter((d) => d.online).length ?? 0
  const pinLeft = st?.pin ? Math.max(0, Math.round((st.pinUntil - now) / 1000)) : 0
  const urls = (st?.addresses ?? []).map((a) => `http://${a}:${st?.port}`)

  return (
    <div className="sb-agent" ref={ref}>
      <button
        className={'sb-item' + (online ? ' ok' : '')}
        title={t('Phone remote — control VIBE CODE from your Android phone', 'Điều khiển từ điện thoại — dùng VIBE CODE trên điện thoại Android')}
        onClick={() => setOpen((o) => !o)}
      >
        <Smartphone size={12} />
        {online > 0 && online}
      </button>
      {open && st && (
        <div className="menu sb-agent-menu remote-panel">
          <label className="remote-row">
            <input type="checkbox" checked={st.enabled} onChange={(e) => void window.api.remote.enable(e.target.checked).then(setSt)} />
            <span className="remote-title">{t('Phone remote', 'Điều khiển từ điện thoại')}</span>
          </label>
          {!st.enabled && (
            <div className="remote-sub">
              {t('Lets a phone on the same Wi-Fi see your chats, send messages and answer Claude.', 'Cho điện thoại cùng Wi-Fi xem các chat, gửi tin nhắn và trả lời Claude.')}
            </div>
          )}
          {st.enabled && (
            <>
              {st.problem && <div className="remote-sub remote-bad">{st.problem}</div>}
              <div className="remote-sub">
                {t('Open the VIBE CODE Remote app on the phone (it finds this PC by itself), or browse to:', 'Mở app VIBE CODE Remote trên điện thoại (app tự tìm máy này), hoặc mở trình duyệt tới:')}
              </div>
              {urls.map((u) => (
                <div key={u} className="remote-url">
                  {u}
                </div>
              ))}
              {st.pin && pinLeft > 0 ? (
                <div className="remote-pin">
                  <div className="remote-pin-code">{st.pin}</div>
                  <div className="remote-sub">{t(`Enter this PIN on the phone · ${pinLeft}s`, `Nhập PIN này trên điện thoại · ${pinLeft}s`)}</div>
                </div>
              ) : (
                <button className="btn btn-primary remote-pair" onClick={() => void window.api.remote.pin().then(setSt)}>
                  {t('Pair a phone', 'Ghép nối điện thoại')}
                </button>
              )}
              <label className="remote-row remote-opt">
                <input type="checkbox" checked={st.desktop} onChange={(e) => void window.api.remote.desktop(e.target.checked).then(setSt)} />
                <span>{t('Allow screen control (mouse, keyboard)', 'Cho điều khiển màn hình (chuột, bàn phím)')}</span>
              </label>
              <div className="menu-sep">{t('From anywhere (4G/5G)', 'Từ bất cứ đâu (4G/5G)')}</div>
              <label className="remote-row">
                <input type="checkbox" checked={st.tunnel} onChange={(e) => void window.api.remote.tunnel(e.target.checked).then(setSt)} />
                <span>{t('Reach it over the Internet', 'Truy cập qua Internet')}</span>
              </label>
              {st.tunnel && <Tunnel st={st} pinLive={pinLeft > 0} />}
              {st.devices.length > 0 && <div className="menu-sep">{t('Paired phones', 'Điện thoại đã ghép')}</div>}
              {st.devices.map((d) => (
                <div key={d.id} className="remote-device">
                  <span className={'remote-dot' + (d.online ? ' on' : '')} />
                  <span className="menu-item-main">{d.name}</span>
                  <button className="icon-btn" title={t('Remove — this phone must pair again', 'Gỡ — điện thoại này phải ghép nối lại')} onClick={() => void window.api.remote.revoke(d.id).then(setSt)}>
                    <Trash2 size={12} />
                  </button>
                </div>
              ))}
            </>
          )}
        </div>
      )}
    </div>
  )
}
