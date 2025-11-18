#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::{
    fs,
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::Arc,
    time::Duration,
};
use tauri::{AppHandle, Manager, State, WindowEvent, Wry};
use tokio::{sync::Mutex, time::sleep};

struct BackendState {
    child: Arc<Mutex<Option<Child>>>,
}

#[derive(Deserialize)]
struct Handshake {
    port: u16,
}

#[tauri::command]
async fn shutdown_backend(state: State<'_, BackendState>) -> Result<(), String> {
    terminate_backend(Arc::clone(&state.child))
        .await
        .map_err(|err| err.to_string())
}

fn main() {
    tauri::Builder::default()
        .manage(BackendState {
            child: Arc::new(Mutex::new(None)),
        })
        .setup(|app| {
            let app_handle = app.handle();
            let state = Arc::clone(&app.state::<BackendState>().child);

            tauri::WindowBuilder::new(
                app,
                "main",
                tauri::WindowUrl::App("index.html".into()),
            )
            .title("Hudson")
            .inner_size(1440.0, 900.0)
            .resizable(true)
            .build()?;

            tauri::async_runtime::spawn(async move {
                if let Err(err) = boot_sequence(app_handle, state).await {
                    eprintln!("Backend boot failed: {err:?}");
                }
            });
            Ok(())
        })
        .on_window_event(|event| {
            if let WindowEvent::CloseRequested { .. } = event.event() {
                let state = Arc::clone(&event.window().state::<BackendState>().child);
                tauri::async_runtime::block_on(async move {
                    let _ = terminate_backend(state).await;
                });
            }
        })
        .invoke_handler(tauri::generate_handler![shutdown_backend])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

async fn boot_sequence(app: AppHandle<Wry>, state: Arc<Mutex<Option<Child>>>) -> Result<()> {
    eprintln!("Boot sequence started");

    let resource_dir = tauri::api::path::resource_dir(app.package_info(), &app.env());
    let child = spawn_backend(resource_dir).context("failed to launch BEAM sidecar")?;
    eprintln!("Backend spawned");

    let port = wait_for_port_file().await?;
    eprintln!("Got port from handshake: {}", port);

    wait_for_health(port).await?;
    eprintln!("Health check passed");

    {
        let mut guard = state.lock().await;
        *guard = Some(child);
    }

    if let Some(window) = app.get_window("main") {
        eprintln!("Navigating window to http://127.0.0.1:{}", port);
        window
            .eval(&format!(
                "window.location.replace('http://127.0.0.1:{port}');"
            ))
            .context("failed to load LiveView into WebView")?;
        eprintln!("Navigation command sent");
    } else {
        return Err(anyhow!("Main window missing"));
    }

    Ok(())
}

fn spawn_backend(resource_dir: Option<PathBuf>) -> Result<Child> {
    let candidates = candidate_backend_paths(resource_dir);

    let executable = candidates
        .iter()
        .find(|path| path.exists())
        .cloned()
        .ok_or_else(|| anyhow!("No backend binary found. Tried: {candidates:?}"))?;

    let args = std::env::var("HUDSON_BACKEND_ARGS")
        .map(|value| value.split_whitespace().map(String::from).collect())
        .unwrap_or_else(|_| default_args_for(&executable));

    let mut command = Command::new(executable);
    if !args.is_empty() {
        command.args(args);
    }

    // Desktop apps default to offline mode (SQLite only) unless explicitly enabled
    let enable_neon = std::env::var("HUDSON_ENABLE_NEON").unwrap_or_else(|_| "false".to_string());
    command.env("HUDSON_ENABLE_NEON", enable_neon);

    command
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .context("failed to spawn backend process")
}

fn candidate_backend_paths(resource_dir: Option<PathBuf>) -> Vec<PathBuf> {
    let mut paths = Vec::new();

    if let Ok(env_path) = std::env::var("HUDSON_BACKEND_BIN") {
        if !env_path.trim().is_empty() {
            paths.push(PathBuf::from(env_path));
        }
    }

    if let Some(dir) = resource_dir {
        // Tauri places externalBin in Contents/MacOS/, check there first
        if let Some(macos_dir) = dir.parent().map(|p| p.join("MacOS")) {
            paths.push(macos_dir.join("hudson_macos_arm-aarch64-apple-darwin"));
            paths.push(macos_dir.join("hudson_macos_arm"));
            paths.push(macos_dir.join("hudson_backend"));
        }
        // Also check Resources/binaries/ (manual bundle location)
        paths.push(dir.join("binaries").join("hudson_macos_arm-aarch64-apple-darwin"));
        paths.push(dir.join("binaries").join("hudson_macos_arm"));
        paths.push(dir.join("binaries").join("hudson_backend"));
        paths.push(dir.join("hudson_macos_arm-aarch64-apple-darwin"));
        paths.push(dir.join("hudson_macos_arm"));
        paths.push(dir.join("hudson_backend"));
    }

    if cfg!(target_os = "windows") {
        paths.push(PathBuf::from("..\\burrito_out\\hudson_windows.exe"));
        paths.push(PathBuf::from("..\\_build\\prod\\rel\\hudson\\bin\\hudson.bat"));
    } else {
        paths.push(PathBuf::from("../burrito_out/hudson_macos_arm"));
        paths.push(PathBuf::from("../burrito_out/hudson_macos_intel"));
        paths.push(PathBuf::from("../_build/prod/rel/hudson/bin/hudson"));
    }

    paths
}

fn default_args_for(executable: &PathBuf) -> Vec<String> {
    let path_str = executable.to_string_lossy();
    if path_str.contains("burrito_out") {
        vec![]
    } else {
        vec!["foreground".to_string()]
    }
}

fn default_backend_path() -> String {
    if cfg!(target_os = "windows") {
        let release = "..\\_build\\prod\\rel\\hudson\\bin\\hudson.bat".to_string();
        if std::path::Path::new(&release).exists() {
            release
        } else {
            "..\\burrito_out\\hudson_windows.exe".to_string()
        }
    } else {
        let release = "../_build/prod/rel/hudson/bin/hudson".to_string();
        if std::path::Path::new(&release).exists() {
            release
        } else if cfg!(target_arch = "aarch64") {
            "../burrito_out/hudson_macos_arm".to_string()
        } else {
            "../burrito_out/hudson_macos_intel".to_string()
        }
    }
}

async fn wait_for_port_file() -> Result<u16> {
    let path = handshake_path();
    for _ in 0..50 {
        if let Ok(contents) = fs::read_to_string(&path) {
            if let Ok(handshake) = serde_json::from_str::<Handshake>(&contents) {
                return Ok(handshake.port);
            }
        }
        sleep(Duration::from_millis(200)).await;
    }

    Err(anyhow!(
        "Timed out waiting for handshake file at {:?}",
        path
    ))
}

fn handshake_path() -> PathBuf {
    if cfg!(target_os = "macos") {
        PathBuf::from("/tmp/hudson_port.json")
    } else if cfg!(target_os = "windows") {
        let base =
            std::env::var("APPDATA").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir());
        base.join("Hudson").join("port.json")
    } else {
        std::env::temp_dir().join("hudson_port.json")
    }
}

async fn wait_for_health(port: u16) -> Result<()> {
    let url = format!("http://127.0.0.1:{port}/healthz");
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()?;

    for _ in 0..40 {
        if let Ok(response) = client.get(&url).send().await {
            if response.status().is_success() {
                return Ok(());
            }
        }
        sleep(Duration::from_millis(250)).await;
    }

    Err(anyhow!("Timed out waiting for /healthz on {url}"))
}

async fn terminate_backend(state: Arc<Mutex<Option<Child>>>) -> Result<()> {
    let mut guard = state.lock().await;
    if let Some(mut child) = guard.take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    Ok(())
}
