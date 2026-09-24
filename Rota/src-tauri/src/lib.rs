use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{fs, process::Command};
use tauri::{Manager, State};

mod mcp;
mod state_store;
use state_store::RotaStore;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct BackendStatus {
    platform: &'static str,
    persistence: &'static str,
    native_input: &'static str,
    accessibility_ready: bool,
    mcp_endpoint: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct InstalledApp {
    name: String,
    path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeAction {
    kind: String,
    value: Option<String>,
}

#[tauri::command]
fn load_state(store: State<'_, RotaStore>) -> Result<Option<Value>, String> {
    store.get()
}

#[tauri::command]
fn save_state(store: State<'_, RotaStore>, state: Value) -> Result<(), String> {
    store.replace(state).map(|_| ())
}

#[tauri::command]
fn backend_status() -> BackendStatus {
    BackendStatus {
        platform: std::env::consts::OS,
        persistence: "Rust · atomic JSON",
        native_input: "Prototype adapter",
        accessibility_ready: false,
        mcp_endpoint: "http://127.0.0.1:4782/mcp",
    }
}

#[tauri::command]
fn list_applications() -> Vec<InstalledApp> {
    let mut applications = Vec::new();
    for root in ["/Applications", "/System/Applications"] {
        let Ok(entries) = fs::read_dir(root) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|extension| extension == "app") {
                let name = path.file_stem().and_then(|name| name.to_str()).unwrap_or("App").to_string();
                applications.push(InstalledApp { name, path: path.display().to_string() });
            }
        }
    }
    applications.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
    applications
}

#[tauri::command]
fn perform_native_action(action: NativeAction) -> Result<String, String> {
    match action.kind.as_str() {
        "open-settings" => {
            let pane = action.value.as_deref().unwrap_or("x-apple.systempreferences:com.apple.Trackpad-Settings.extension");
            Command::new("open").arg(pane).spawn().map_err(|error| error.to_string())?;
            Ok("Opened System Settings".into())
        }
        "open-app" => {
            let target = action.value.ok_or_else(|| "Missing application path".to_string())?;
            Command::new("open").arg(target).spawn().map_err(|error| error.to_string())?;
            Ok("Opened application".into())
        }
        "reconnect" => Ok("Input adapters reloaded".into()),
        "test-action" => Ok(action.value.unwrap_or_else(|| "Action dispatched".into())),
        _ => Err(format!("Unsupported native action: {}", action.kind)),
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let directory = app.path().app_data_dir().map_err(|error| error.to_string())?;
            fs::create_dir_all(&directory)?;
            let store = RotaStore::new(directory.join("rota-state.json"));
            app.manage(store.clone());
            tauri::async_runtime::spawn(async move {
                if let Err(error) = mcp::serve(store).await {
                    eprintln!("Rota MCP server stopped: {error}");
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            load_state,
            save_state,
            backend_status,
            list_applications,
            perform_native_action
        ])
        .run(tauri::generate_context!())
        .expect("error while running Rota");
}
