export type SectionId = "devices" | "hud" | "calibration" | "commands" | "overrides" | "pointer" | "general";
export type HudDirection = "left" | "right" | "up" | "down";
export type HudTheme = "graphite" | "starburst" | "air";

export interface Tile {
  id: string;
  label: string;
  icon: string;
  action: string;
  detail?: string;
  children?: Tile[];
}

export interface HudLayer {
  id: string;
  name: string;
  position: HudDirection;
  slots: number;
  accent: string;
  shortcut: string;
  app?: string;
  tiles: Tile[];
}

export interface MacroStep {
  id: string;
  type: "keys" | "app" | "delay";
  value: string;
  delay: number;
}

export interface RotaMacro {
  id: string;
  name: string;
  shortcut: string;
  steps: MacroStep[];
}

export interface AppOverride {
  id: string;
  app: string;
  detail: string;
  enabled: boolean;
  gesture: string;
  action: string;
}

export interface PointerSettings {
  cursorSpeed: number;
  cursorAcceleration: number;
  smoothing: number;
  scrollSpeed: number;
  scrollAcceleration: number;
  coast: number;
  invertX: boolean;
  invertY: boolean;
  kinetic: boolean;
  tapDrag: boolean;
  regrip: boolean;
}

export interface CalibrationSettings {
  device: "navigator" | "apple";
  tapDuration: number;
  tapMovement: number;
  doubleTapDelay: number;
  swipeDistance: number;
  swipeDuration: number;
}

export interface Profile {
  id: string;
  name: string;
  layers: HudLayer[];
  pointer: PointerSettings;
  calibration: CalibrationSettings;
}

export interface RotaState {
  enabled: boolean;
  launchAtLogin: boolean;
  activeProfileId: string;
  activeLayerId: string;
  profiles: Profile[];
  navigatorEnabled: boolean;
  appleEnabled: boolean;
  appleInputAllowed: boolean;
  shareActions: boolean;
  hudTheme: HudTheme;
  hudAnimations: boolean;
  macros: RotaMacro[];
  overrides: AppOverride[];
  syncEnabled: boolean;
  syncEndpoint: string;
}

export interface BackendStatus {
  platform: string;
  persistence: string;
  nativeInput: string;
  accessibilityReady: boolean;
  mcpEndpoint: string;
}

export interface InstalledApp {
  name: string;
  path: string;
}
