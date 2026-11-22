//! Browser extensions in the Web tabs, beside the built-in ad blocker (adblock.rs): added from the
//! Chrome Web Store (a link or an id) or from an unpacked folder. WebView2 keeps them in the Web
//! tabs' profile; `extensions/index.json` remembers each one's folder, to find its options page.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::LazyLock,
};

use anyhow::{Context, bail};
use regex::Regex;
use serde::Serialize;

use crate::core::{Res, command, err, user_data};
use crate::settings::tr;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtInfo {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    /// the ad blocker: switched with the shield setting, not removable
    pub builtin: bool,
    /// its settings page (chrome-extension://…), when it has one
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<String>,
}

fn root() -> PathBuf {
    user_data().join("extensions")
}

fn index() -> HashMap<String, PathBuf> {
    std::fs::read(root().join("index.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_index(map: &HashMap<String, PathBuf>) {
    let _ = std::fs::create_dir_all(root());
    let _ = std::fs::write(root().join("index.json"), serde_json::to_vec_pretty(map).unwrap_or_default());
}

/// The page to open as its settings: options page, else the toolbar popup (WebView2 has no toolbar).
fn options_page(dir: &Path) -> Option<String> {
    let m: serde_json::Value = serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).ok()?).ok()?;
    [&m["options_ui"]["page"], &m["options_page"], &m["action"]["default_popup"], &m["browser_action"]["default_popup"]]
        .into_iter()
        .find_map(|v| v.as_str().filter(|s| !s.is_empty()))
        .map(|p| p.trim_start_matches('/').to_owned())
}

/// The extension's folder on disk: the ad blocker's, or one added here.
fn folder_of(id: &str, builtin: bool) -> Option<PathBuf> {
    if builtin {
        // the ad blocker (adblock module) only exists on Windows
        #[cfg(windows)]
        return crate::adblock::installed().map(|(_, d)| d);
        #[cfg(not(windows))]
        return None;
    }
    index().remove(id)
}

pub fn info(id: String, name: String, enabled: bool) -> ExtInfo {
    #[cfg(windows)]
    let builtin = name.starts_with(crate::adblock::NAME);
    #[cfg(not(windows))]
    let builtin = false;
    let options = folder_of(&id, builtin).and_then(|d| options_page(&d)).map(|p| format!("chrome-extension://{id}/{p}"));
    ExtInfo { id, name, enabled, builtin, options }
}

/// A Web Store link ("https://chromewebstore.google.com/detail/name/<id>") or a bare id → the id.
fn store_id(input: &str) -> Option<String> {
    static ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b[a-p]{32}\b").unwrap());
    ID.find(input).map(|m| m.as_str().to_owned())
}

/// Downloads a Web Store extension and unpacks it into `extensions/<id>`.
async fn download(id: &str) -> anyhow::Result<PathBuf> {
    let url = format!(
        "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0&acceptformat=crx2,crx3&x=id%3D{id}%26installsource%3Dondemand%26uc"
    );
    let crx = reqwest::Client::new().get(url).header("User-Agent", "vibe-code").send().await?.error_for_status()?.bytes().await?;
    // CRX = "Cr24", version, then (v3) a header of `len` bytes or (v2) a key and a signature; the zip follows
    if crx.len() < 16 || &crx[..4] != b"Cr24" {
        bail!(
            "{}",
            tr(
                "the Web Store did not send an extension (is the id right, and is it a Chrome extension?)",
                "Web Store không gửi về tiện ích nào (id có đúng không, và đó có phải tiện ích Chrome không?)"
            )
        );
    }
    let n = |at: usize| u32::from_le_bytes(crx[at..at + 4].try_into().unwrap()) as usize;
    let start = match n(4) {
        3 => 12 + n(8),
        2 => 16 + n(8) + n(12),
        v => bail!("unknown extension package version {v}"),
    };
    let zip = crx.get(start..).context("the extension package is cut short")?;

    let root = root();
    tokio::fs::create_dir_all(&root).await?;
    let (file, part, done) = (root.join(format!("{id}.zip")), root.join(format!("{id}.part")), root.join(id));
    tokio::fs::write(&file, zip).await?;
    let _ = tokio::fs::remove_dir_all(&part).await;
    let quote = |p: &Path| format!("'{}'", p.to_string_lossy().replace('\'', "''"));
    let out = command("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &format!("Expand-Archive -LiteralPath {} -DestinationPath {} -Force", quote(&file), quote(&part))])
        .output()
        .await?;
    let _ = tokio::fs::remove_file(&file).await;
    if !out.status.success() || !part.join("manifest.json").is_file() {
        let _ = tokio::fs::remove_dir_all(&part).await;
        bail!("{} {}", tr("could not unpack the extension:", "không giải nén được tiện ích:"), String::from_utf8_lossy(&out.stderr).trim());
    }
    // the store's signature folder: names starting with "_" are refused when loading unpacked
    let _ = tokio::fs::remove_dir_all(part.join("_metadata")).await;
    let _ = tokio::fs::remove_dir_all(&done).await;
    tokio::fs::rename(&part, &done).await?;
    Ok(done)
}

/// Extensions the Web tabs come with (beside the ad blocker): added once, so one you remove stays removed.
const DEFAULTS: [&str; 1] = [
    // Claude in Chrome
    "fcoeoabgfenejglbffodgkkbkcdhcgfn",
];

/// Startup: adds the default extensions not added before.
pub async fn install_defaults() {
    if !cfg!(windows) {
        return;
    }
    let marker = root().join("defaults.txt");
    let mut done: Vec<String> = std::fs::read_to_string(&marker).unwrap_or_default().lines().map(str::to_owned).collect();
    for id in DEFAULTS {
        if done.iter().any(|d| d == id) {
            continue;
        }
        let added = async {
            let dir = download(id).await?;
            let (got, _, _) = crate::browser::add_extension(&dir).await?;
            let mut map = index();
            map.insert(got, dir);
            save_index(&map);
            anyhow::Ok(())
        };
        match added.await {
            Ok(()) => done.push(id.to_owned()),
            // offline, or WebView2 refused it: tried again next launch
            Err(e) => eprintln!("default extension {id}: {e:#}"),
        }
    }
    let _ = std::fs::write(marker, done.join("\n"));
}

/* ---------------- commands ---------------- */

#[tauri::command]
pub async fn web_extensions() -> Res<Vec<ExtInfo>> {
    Ok(crate::browser::extensions().await?)
}

/// Adds an extension from a Web Store link / id, or from an unpacked folder (one with manifest.json).
#[tauri::command]
pub async fn web_extension_add(source: String) -> Res<ExtInfo> {
    let source = source.trim();
    let folder = Path::new(source);
    let dir = if folder.join("manifest.json").is_file() {
        folder.to_owned()
    } else if let Some(id) = store_id(source) {
        download(&id).await?
    } else {
        return Err(err(tr(
            "Paste a Chrome Web Store link (or the extension's id), or pick a folder that has a manifest.json.",
            "Dán link Chrome Web Store (hoặc id của tiện ích), hoặc chọn một thư mục có manifest.json.",
        )));
    };
    let (id, name, on) = crate::browser::add_extension(&dir).await?;
    let mut map = index();
    map.insert(id.clone(), dir);
    save_index(&map);
    Ok(info(id, name, on))
}

#[tauri::command]
pub async fn web_extension_enable(id: String, on: bool) -> Res<()> {
    Ok(crate::browser::extension_enable(&id, on).await?)
}

#[tauri::command]
pub async fn web_extension_remove(id: String) -> Res<()> {
    crate::browser::extension_remove(&id).await?;
    let mut map = index();
    // a Web Store download is ours to delete; a folder you picked stays where it is
    if let Some(dir) = map.remove(&id)
        && dir.starts_with(root())
    {
        let _ = std::fs::remove_dir_all(dir);
    }
    save_index(&map);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids() {
        assert_eq!(
            store_id("https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=en").as_deref(),
            Some("ddkjiahejlhfcafbddmgiahcphecmpfh")
        );
        assert_eq!(store_id("ddkjiahejlhfcafbddmgiahcphecmpfh").as_deref(), Some("ddkjiahejlhfcafbddmgiahcphecmpfh"));
        assert_eq!(store_id("not an id"), None);
    }
}
