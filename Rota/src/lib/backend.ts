import { invoke } from "@tauri-apps/api/core";
import type { BackendStatus, InstalledApp, RotaState } from "../types";

const inTauri = () => "__TAURI_INTERNALS__" in window;
const fallbackKey = "rota-state";

export async function loadState(): Promise<RotaState | null> {
  if (inTauri()) return invoke<RotaState | null>("load_state");
  const value = localStorage.getItem(fallbackKey);
  return value ? JSON.parse(value) as RotaState : null;
}

export async function saveState(state: RotaState): Promise<void> {
  if (inTauri()) return invoke("save_state", { state });
  localStorage.setItem(fallbackKey, JSON.stringify(state));
}

export async function getBackendStatus(): Promise<BackendStatus> {
  if (inTauri()) return invoke<BackendStatus>("backend_status");
  return { platform: "browser", persistence: "Browser · local storage", nativeInput: "Preview simulator", accessibilityReady: false, mcpEndpoint: "Starts with the Rota desktop app" };
}

export async function listApplications(): Promise<InstalledApp[]> {
  if (inTauri()) return invoke<InstalledApp[]>("list_applications");
  return ["Finder", "Safari", "Mail", "Calendar", "Notes"].map(name => ({ name, path: `/Applications/${name}.app` }));
}

export async function nativeAction(kind: string, value?: string): Promise<string> {
  if (inTauri()) return invoke<string>("perform_native_action", { action: { kind, value } });
  return kind === "reconnect" ? "Preview adapters reloaded" : `${value ?? "Action"} dispatched`;
}
