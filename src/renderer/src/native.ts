/**
 * The page side of the native bridge (`window.__VIBE__`, injected by the Zig host before any
 * script runs): `invoke` a command, `listen` to an event, stream with a `Channel`.
 */

type Bridge = {
  invoke: (cmd: string, args?: unknown, opts?: { headers?: Record<string, string> }) => Promise<unknown>
  listen: (event: string, cb: (e: { event: string; payload: unknown }) => void) => () => void
  Channel: new () => { onmessage: (m: unknown) => void }
}

const bridge = (): Bridge => {
  const b = (window as unknown as { __VIBE__?: Bridge }).__VIBE__
  if (!b) throw new Error('not running inside VIBE CODE')
  return b
}

export type UnlistenFn = () => void

/** Calls a native command: `args` as JSON, or a Uint8Array / ArrayBuffer as the raw body. */
export function invoke<T = void>(cmd: string, args?: unknown, opts?: { headers?: Record<string, string> }): Promise<T> {
  return bridge().invoke(cmd, args, opts) as Promise<T>
}

/** Native event; resolves with the function that stops listening. */
export function listen<T>(event: string, cb: (e: { event: string; payload: T }) => void): Promise<UnlistenFn> {
  return Promise.resolve(bridge().listen(event, cb as (e: { event: string; payload: unknown }) => void))
}

/** A stream of messages from one native call (pass it in the call's arguments). */
export class Channel<T> {
  private ch = new (bridge().Channel)()
  set onmessage(f: (m: T) => void) {
    this.ch.onmessage = f as (m: unknown) => void
  }
  toJSON(): unknown {
    return (this.ch as unknown as { toJSON: () => unknown }).toJSON()
  }
}
