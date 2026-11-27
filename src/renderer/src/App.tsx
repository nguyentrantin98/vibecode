import { useEffect } from 'react'
import { Group, Panel, Separator, useDefaultLayout } from 'react-resizable-panels'
import { useStore } from './store'
import { applyTheme, detectClaude, loadSessions, openFolder, refreshGit, showChatBrowser } from './actions'
import { onGlobalKey } from './shortcuts'
import { focusTerm } from './terminals'
import { reloadIfClean } from './fileModelsLite'
import { syncLang } from './i18n'
import { ActivityBar, QuickOpen, StatusBar, TitleBar, Welcome } from './components/Chrome'
import { Sidebar } from './components/Sidebar'
import { EditorArea } from './components/Editor'
import { BottomPanel, ClaudePanel } from './components/Claude'
import { ContextMenuHost } from './components/ContextMenu'
import { TooltipHost } from './components/Tooltip'

function useGlobalKeys(): void {
  useEffect(() => {
    // capture phase: runs before xterm / monaco swallow the keystroke (see shortcuts.ts)
    window.addEventListener('keydown', onGlobalKey, true)
    return () => window.removeEventListener('keydown', onGlobalKey, true)
  }, [])
  // "new Zalo task" notification clicked → show the Zalo tab
  useEffect(() => window.api.zalo.onShowTasks(() => useStore.setState({ centerView: 'zalo' })), [])
}

function useBoot(): void {
  useEffect(() => {
    ;(async () => {
      const [settings] = await Promise.all([window.api.app.settings(), detectClaude()])
      useStore.setState({ recent: settings.recentFolders, settings })
      syncLang(settings.language)
      applyTheme()
      if (settings.lastFolder) openFolder(settings.lastFolder).catch(() => {})
    })()

    window.api.win.state().then((win) => useStore.setState({ win }))
    loadSessions()

    const offs = [
      window.api.fs.onChanged((paths) => {
        refreshGit()
        // the explorer's folders listen to 'fs-changed' and re-read only the ones touched
        for (const p of paths) reloadIfClean(p)
        window.dispatchEvent(new CustomEvent('fs-changed', { detail: paths }))
      }),
      window.api.fs.onGitChanged(() => {
        refreshGit()
        window.dispatchEvent(new Event('git-changed'))
      }),
      window.api.sessions.onChanged(loadSessions),
      window.api.browser.onOpen(showChatBrowser),
      window.api.win.onState((win) => useStore.setState({ win })),
      // drop-down just slid in → put the cursor straight into the active chat
      window.api.win.onShown(() => {
        const id = useStore.getState().activeChatId
        if (id) focusTerm(id)
      })
    ]
    return () => offs.forEach((off) => off())
  }, [])
}

function Handle({ dir }: { dir: 'h' | 'v' }): React.JSX.Element {
  return <Separator className={`resize-handle ${dir}`} />
}

export default function App(): React.JSX.Element {
  useBoot()
  useGlobalKeys()
  const root = useStore((s) => s.root)
  const sidebarOpen = useStore((s) => s.sidebarOpen)
  const bottomOpen = useStore((s) => s.bottomOpen)
  const quickOpen = useStore((s) => s.quickOpen)
  const dropdown = useStore((s) => s.win?.mode === 'dropdown')
  // layouts are remembered per set of visible panels (sidebar / bottom panel can be toggled)
  // chats on the left (one column each), the center tabs on the right
  const layoutH = useDefaultLayout({ id: 'layout-cols', panelIds: sidebarOpen ? ['sidebar', 'claude', 'center'] : ['claude', 'center'], storage: localStorage })
  const layoutV = useDefaultLayout({ id: 'layout-v', panelIds: bottomOpen ? ['editor', 'bottom'] : ['editor'], storage: localStorage })

  return (
    <div className={`app${dropdown ? ' mode-dropdown' : ''}`}>
      <TitleBar />
      {!root ? (
        <Welcome />
      ) : (
        <div className="workbench">
          <ActivityBar />
          <Group orientation="horizontal" className="panels" defaultLayout={layoutH.defaultLayout} onLayoutChanged={layoutH.onLayoutChanged}>
            {sidebarOpen && (
              <>
                <Panel id="sidebar" defaultSize="16%" minSize="11%" maxSize="35%">
                  <Sidebar />
                </Panel>
                <Handle dir="h" />
              </>
            )}
            <Panel id="claude" defaultSize="52%" minSize="20%">
              <ClaudePanel />
            </Panel>
            <Handle dir="h" />
            <Panel id="center" defaultSize="32%" minSize="15%">
              <Group orientation="vertical" defaultLayout={layoutV.defaultLayout} onLayoutChanged={layoutV.onLayoutChanged}>
                <Panel id="editor" defaultSize="68%" minSize="20%">
                  <EditorArea />
                </Panel>
                {bottomOpen && (
                  <>
                    <Handle dir="v" />
                    <Panel id="bottom" defaultSize="32%" minSize="12%">
                      <BottomPanel />
                    </Panel>
                  </>
                )}
              </Group>
            </Panel>
          </Group>
        </div>
      )}
      <StatusBar />
      {quickOpen && <QuickOpen />}
      <ContextMenuHost />
      <TooltipHost />
    </div>
  )
}
