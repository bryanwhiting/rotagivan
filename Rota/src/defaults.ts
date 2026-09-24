import type { HudLayer, Profile, RotaState, Tile } from "./types";

const tile = (label: string, icon: string, action: string, detail?: string): Tile => ({
  id: crypto.randomUUID(), label, icon, action, detail
});

const mainTiles = (): Tile[] => {
  const windows = tile("Windows", "▦", "Window Manager", "8 layouts");
  windows.children = [
    tile("Left ⅓", "⅓", "Window placement"),
    tile("Left ½", "½", "Window placement"),
    tile("Left ⅔", "⅔", "Window placement")
  ];
  return [
    tile("Finder", "◫", "Open app", "com.apple.finder"),
    tile("Search", "⌕", "Keystroke", "⌘ Space"),
    tile("Mission", "✣", "System command", "Mission Control"),
    tile("Actions", "⌘", "Reserved group", "Copy · Paste · Undo"),
    windows,
    tile("Recent", "↺", "Recent Apps", "Live group"),
    tile("Media", "◖", "Media Controls", "Playback"),
    tile("Notes", "✎", "Open app", "com.apple.Notes")
  ];
};

const layer = (name: string, position: HudLayer["position"], accent: string, labels: string[]): HudLayer => ({
  id: crypto.randomUUID(), name, position, accent, shortcut: "", slots: labels.length,
  tiles: labels.map((label, index) => tile(label, ["◫", "⌘", "↗", "◆", "✦", "◎", "▦", "↺"][index % 8], "Action"))
});

export function createProfile(name = "Default"): Profile {
  const main: HudLayer = {
    id: "main", name: "Main HUD", position: "right", slots: 8, accent: "#9fe870", shortcut: "⌥ Space", tiles: mainTiles()
  };
  return {
    id: crypto.randomUUID(), name,
    layers: [
      main,
      layer("Work", "right", "#ffb45c", ["Mail", "Calendar", "Slack", "Browser", "Tasks", "Docs", "Meet", "Focus"]),
      layer("Create", "up", "#78b8ff", ["Canvas", "Notes", "Capture", "Music"]),
      layer("Window Lab", "down", "#f48fb1", ["Left ½", "Right ½", "Top ½", "Bottom ½", "Left ⅓", "Center ⅓", "Right ⅓", "Full"])
    ],
    pointer: {
      cursorSpeed: 50, cursorAcceleration: 52, smoothing: 28,
      scrollSpeed: 50, scrollAcceleration: 50, coast: 50,
      invertX: false, invertY: false, kinetic: true, tapDrag: true, regrip: true
    },
    calibration: {
      device: "navigator", tapDuration: 180, tapMovement: 24,
      doubleTapDelay: 260, swipeDistance: 80, swipeDuration: 350
    }
  };
}

export function createDefaultState(): RotaState {
  const profile = createProfile();
  return {
    enabled: true,
    launchAtLogin: false,
    activeProfileId: profile.id,
    activeLayerId: "main",
    profiles: [profile],
    navigatorEnabled: true,
    appleEnabled: true,
    appleInputAllowed: false,
    shareActions: true,
    hudTheme: "air",
    hudAnimations: true,
    macros: [
      {
        id: crypto.randomUUID(), name: "Open & search", shortcut: "⌃⌥ S",
        steps: [
          { id: crypto.randomUUID(), type: "app", value: "Safari", delay: 160 },
          { id: crypto.randomUUID(), type: "keys", value: "⌘ L", delay: 80 },
          { id: crypto.randomUUID(), type: "keys", value: "⌘ V", delay: 50 },
          { id: crypto.randomUUID(), type: "keys", value: "Return", delay: 0 }
        ]
      }
    ],
    overrides: [
      { id: crypto.randomUUID(), app: "Safari", detail: "Browsing", enabled: true, gesture: "Two-finger left", action: "Previous tab" },
      { id: crypto.randomUUID(), app: "Finder", detail: "Files", enabled: true, gesture: "Two-finger right", action: "Main HUD" }
    ],
    syncEnabled: false,
    syncEndpoint: ""
  };
}
