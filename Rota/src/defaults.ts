import type { HudLayer, Profile, RotaState, Tile } from "./types";

const tile = (label: string, icon: string, action: string, detail?: string): Tile => ({
  id: crypto.randomUUID(), label, icon, action, detail
});

const mainTiles = (): Tile[] => {
  const windows = tile("Windows", "▦", "Left Half", "Hold for more layouts");
  windows.children = [
    tile("Left ⅓", "⅓", "Left Third"),
    tile("Left ½", "½", "Left Half"),
    tile("Full", "□", "Fill Desktop")
  ];
  return [
    tile("Finder", "◫", "Open App", "com.apple.finder"),
    tile("Search", "⌕", "Find", "⌘ F"),
    tile("Mission", "✣", "Mission Control"),
    tile("Actions", "⌘", "Copy", "Copy · Paste · Undo"),
    windows,
    tile("Recent", "↺", "Recent Apps", "Live group"),
    tile("Media", "◖", "Play / Pause", "Playback"),
    tile("Notes", "✎", "Open App", "com.apple.Notes")
  ];
};

const layer = (name: string, position: HudLayer["position"], accent: string, labels: string[]): HudLayer => ({
  id: crypto.randomUUID(), name, position, accent, shortcut: "", slots: labels.length,
  tiles: labels.map((label, index) => tile(label, ["◫", "⌘", "↗", "◆", "✦", "◎", "▦", "↺"][index % 8], name === "Window Lab" ? ["Left Half", "Right Half", "Top Half", "Bottom Half", "Left Third", "Center Third", "Right Third", "Fill Desktop"][index] : "Open App"))
});

export function createProfile(name = "Default"): Profile {
  const main: HudLayer = {
    id: "main", name: "Main HUD", position: "right", slots: 8, accent: "#69c9ff", shortcut: "⌥ Space", tiles: mainTiles()
  };
  return {
    id: crypto.randomUUID(), name,
    layers: [
      main,
      layer("Work", "right", "#84bfff", ["Mail", "Calendar", "Slack", "Browser", "Tasks", "Docs", "Meet", "Focus"]),
      layer("Create", "up", "#55d5ff", ["Canvas", "Notes", "Capture", "Music"]),
      layer("Window Lab", "down", "#9ac8ff", ["Left ½", "Right ½", "Top ½", "Bottom ½", "Left ⅓", "Center ⅓", "Right ⅓", "Full"])
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
      { id: crypto.randomUUID(), app: "Safari", detail: "Browsing", enabled: true, gesture: "Two-finger left", action: "Previous Desktop" },
      { id: crypto.randomUUID(), app: "Finder", detail: "Files", enabled: true, gesture: "Two-finger right", action: "Mission Control" }
    ],
    syncEnabled: false,
    syncEndpoint: ""
  };
}
