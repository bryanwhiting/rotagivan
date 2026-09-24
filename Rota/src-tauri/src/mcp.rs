use crate::state_store::RotaStore;
use axum::Router;
use rmcp::{
    Json, ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{Implementation, ServerCapabilities, ServerConfig},
    tool, tool_handler, tool_router,
    transport::{StreamableHttpServerConfig, StreamableHttpService,
        streamable_http_server::session::local::LocalSessionManager},
};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

pub const MCP_ADDRESS: &str = "127.0.0.1:4782";

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PointerRequest {
    /// RFC 6901 JSON Pointer, for example /profiles/0/pointer/cursorSpeed.
    pub pointer: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SetRequest {
    /// Existing RFC 6901 JSON Pointer to edit.
    pub pointer: String,
    /// Replacement JSON value. Types and bounds should match the current value.
    pub value: Value,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ReplaceRequest {
    /// Complete Rota settings object, normally based on rota_get_settings output.
    pub state: Value,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PatchRequest {
    /// RFC 6902 JSON Patch array. Supports add, remove, replace, move, copy, and test operations.
    pub patch: Value,
}

#[derive(Clone)]
pub struct RotaMcp {
    store: RotaStore,
    tool_router: ToolRouter<Self>,
}

#[tool_router(router = tool_router)]
impl RotaMcp {
    pub fn new(store: RotaStore) -> Self {
        Self { store, tool_router: Self::tool_router() }
    }

    #[tool(name = "rota_get_settings", description = "Read the complete live Rota configuration. Use this before editing so IDs, indices, value types, and current settings are preserved.")]
    async fn get_settings(&self) -> Result<Json<Value>, String> {
        Ok(Json(self.store.get()?.unwrap_or_else(|| json!({ "status": "Rota settings are not initialized; open Rota once." }))))
    }

    #[tool(name = "rota_get_setting", description = "Read one Rota setting using an RFC 6901 JSON Pointer.")]
    async fn get_setting(&self, Parameters(request): Parameters<PointerRequest>) -> Result<Json<Value>, String> {
        let state = self.store.get()?.ok_or_else(|| "Rota settings are not initialized".to_string())?;
        state.pointer(&request.pointer).cloned().map(Json).ok_or_else(|| format!("Setting path does not exist: {}", request.pointer))
    }

    #[tool(name = "rota_set_setting", description = "Edit any existing Rota setting using an RFC 6901 JSON Pointer. Read settings first and preserve the existing JSON type. This covers devices, HUD layers/tiles, motion, calibration, Custom Commands, overrides, sync, and general settings.")]
    async fn set_setting(&self, Parameters(request): Parameters<SetRequest>) -> Result<Json<Value>, String> {
        self.store.set_pointer(&request.pointer, request.value).map(Json)
    }

    #[tool(name = "rota_delete_setting", description = "Delete an object property or array element from Rota settings using an RFC 6901 JSON Pointer. Intended for removing profiles, layers, tiles, Custom Commands, and overrides after reading current settings.")]
    async fn delete_setting(&self, Parameters(request): Parameters<PointerRequest>) -> Result<Json<Value>, String> {
        self.store.delete_pointer(&request.pointer).map(Json)
    }

    #[tool(name = "rota_replace_settings", description = "Replace the complete Rota configuration atomically. Use for multi-field edits after calling rota_get_settings. The root must remain a JSON object.")]
    async fn replace_settings(&self, Parameters(request): Parameters<ReplaceRequest>) -> Result<Json<Value>, String> {
        self.store.replace(request.state).map(Json)
    }

    #[tool(name = "rota_patch_settings", description = "Atomically apply an RFC 6902 JSON Patch to Rota settings. This is the preferred way to add, remove, reorder, or change multiple profiles, layers, tiles, Custom Commands, and overrides.")]
    async fn patch_settings(&self, Parameters(request): Parameters<PatchRequest>) -> Result<Json<Value>, String> {
        self.store.apply_patch(request.patch).map(Json)
    }

    #[tool(name = "rota_settings_guide", description = "Return the editable Rota settings map, constraints, and MCP endpoint information.")]
    async fn settings_guide(&self) -> Json<Value> {
        Json(json!({
            "endpoint": "http://127.0.0.1:4782/mcp",
            "transport": "MCP Streamable HTTP",
            "editing": "Call rota_get_settings, then edit an existing JSON Pointer or replace the full object.",
            "topLevel": {
                "enabled": "boolean", "launchAtLogin": "boolean", "activeProfileId": "profile UUID",
                "activeLayerId": "layer ID", "profiles": "profiles with layers, tiles, pointer, calibration",
                "navigatorEnabled": "boolean", "appleEnabled": "boolean", "appleInputAllowed": "boolean",
                "shareActions": "boolean", "hudTheme": "graphite | starburst | air", "hudAnimations": "boolean",
                "macros": "Custom Commands array (legacy storage key)", "overrides": "app override array", "syncEnabled": "boolean", "syncEndpoint": "string"
            },
            "actionHierarchy": [
                { "family": "Window Management", "actions": ["Left Half", "Right Half", "Top Half", "Bottom Half", "Left Third", "Center Third", "Right Third", "Fill Desktop", "Toggle Full Screen", "Minimize Window", "Close Window"] },
                { "family": "Media Control", "actions": ["Play / Pause", "Previous Track", "Next Track", "Volume Up", "Volume Down", "Mute"] },
                { "family": "System Actions", "actions": ["Copy", "Paste", "Cut", "Undo", "Redo", "Select All", "Save", "Find"] },
                { "family": "macOS Settings", "actions": ["Mission Control", "Previous Desktop", "Next Desktop", "Show Desktop", "App Windows", "Trackpad Settings", "Accessibility Settings"] },
                { "family": "Open Apps & Bookmarks", "actions": ["Open App", "Open Bookmark", "Recent Apps", "Current App Windows"] },
                { "family": "Custom Commands", "actions": ["Run Custom Command", "Keystroke Sequence", "Create Custom Command"] }
            ],
            "recommended": "Preserve IDs, keep HUD slot counts from 2 through 16, and keep percentage controls from 0 through 100."
        }))
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for RotaMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("Rota", env!("CARGO_PKG_VERSION")))
            .with_instructions("Rota is a trackpad and spatial-HUD settings server. Read settings before editing them. All settings exposed by the Rota UI can be edited with the provided tools.")
    }
}

pub async fn serve(store: RotaStore) -> Result<(), String> {
    let service = StreamableHttpService::new(
        move || Ok(RotaMcp::new(store.clone())),
        Arc::new(LocalSessionManager::default()),
        StreamableHttpServerConfig::default(),
    );
    let router = Router::new().nest_service("/mcp", service);
    let listener = tokio::net::TcpListener::bind(MCP_ADDRESS).await.map_err(|error| error.to_string())?;
    axum::serve(listener, router).await.map_err(|error| error.to_string())
}
