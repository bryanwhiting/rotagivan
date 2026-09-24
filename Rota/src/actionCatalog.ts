export interface ActionDefinition {
  label: string;
  detail: string;
}

export interface ActionCategory {
  id: "window" | "media" | "system" | "macos" | "open" | "custom";
  label: string;
  shortLabel: string;
  glyph: string;
  description: string;
  actions: ActionDefinition[];
}

export const ACTION_CATEGORIES: ActionCategory[] = [
  {
    id: "window", label: "Window Management", shortLabel: "Windows", glyph: "▦",
    description: "Place, resize, focus, and close windows.",
    actions: ["Left Half", "Right Half", "Top Half", "Bottom Half", "Left Third", "Center Third", "Right Third", "Fill Desktop", "Toggle Full Screen", "Minimize Window", "Close Window"].map(label => ({ label, detail: "Window layout" }))
  },
  {
    id: "media", label: "Media Control", shortLabel: "Media", glyph: "◖",
    description: "Control playback and system volume.",
    actions: ["Play / Pause", "Previous Track", "Next Track", "Volume Up", "Volume Down", "Mute"].map(label => ({ label, detail: "Media key" }))
  },
  {
    id: "system", label: "System Actions", shortLabel: "System", glyph: "⌘",
    description: "Everyday edit, file, and search commands.",
    actions: ["Copy", "Paste", "Cut", "Undo", "Redo", "Select All", "Save", "Find"].map(label => ({ label, detail: "macOS shortcut" }))
  },
  {
    id: "macos", label: "macOS Settings", shortLabel: "macOS", glyph: "✣",
    description: "Navigate desktops and invoke macOS controls.",
    actions: ["Mission Control", "Previous Desktop", "Next Desktop", "Show Desktop", "App Windows", "Trackpad Settings", "Accessibility Settings"].map(label => ({ label, detail: "macOS control" }))
  },
  {
    id: "open", label: "Open Apps & Bookmarks", shortLabel: "Open", glyph: "↗",
    description: "Launch apps, bookmarks, and recent destinations.",
    actions: ["Open App", "Open Bookmark", "Recent Apps", "Current App Windows"].map(label => ({ label, detail: "Destination" }))
  },
  {
    id: "custom", label: "Custom Commands", shortLabel: "Custom", glyph: "◆",
    description: "Run reusable commands and key sequences.",
    actions: ["Run Custom Command", "Keystroke Sequence", "Create Custom Command"].map(label => ({ label, detail: "Custom automation" }))
  }
];

const LEGACY_ACTIONS: Record<string, string> = {
  "Open app": "Open App",
  "Open URL": "Open Bookmark",
  "Keystroke": "Keystroke Sequence",
  "Macro": "Run Custom Command",
  "Window Manager": "Left Half",
  "Window placement": "Left Half",
  "Media Controls": "Play / Pause",
  "System command": "Mission Control",
  "Reserved group": "Copy",
  "Action": "Run Custom Command",
  "Previous tab": "Keystroke Sequence",
  "Main HUD": "Run Custom Command"
};

export function canonicalAction(action: string) {
  return LEGACY_ACTIONS[action] ?? action;
}

export function actionCategoryFor(action: string) {
  return ACTION_CATEGORIES.find(category => category.actions.some(item => item.label === action));
}
