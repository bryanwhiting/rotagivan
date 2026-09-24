use tauri::{
    menu::{Menu, MenuBuilder, MenuItemBuilder, Submenu, SubmenuBuilder},
    AppHandle, Wry,
};

const ACTION_FAMILIES: &[(&str, &[&str])] = &[
    (
        "Window Management",
        &[
            "Left Half",
            "Right Half",
            "Top Half",
            "Bottom Half",
            "Left Third",
            "Center Third",
            "Right Third",
            "Fill Desktop",
            "Toggle Full Screen",
            "Minimize Window",
            "Close Window",
        ],
    ),
    (
        "Media Control",
        &[
            "Play / Pause",
            "Previous Track",
            "Next Track",
            "Volume Up",
            "Volume Down",
            "Mute",
        ],
    ),
    (
        "System Actions",
        &[
            "Copy",
            "Paste",
            "Cut",
            "Undo",
            "Redo",
            "Select All",
            "Save",
            "Find",
        ],
    ),
    (
        "macOS Settings",
        &[
            "Mission Control",
            "Previous Desktop",
            "Next Desktop",
            "Show Desktop",
            "App Windows",
            "Trackpad Settings",
            "Accessibility Settings",
        ],
    ),
    (
        "Open Apps & Bookmarks",
        &[
            "Open App",
            "Open Bookmark",
            "Recent Apps",
            "Current App Windows",
        ],
    ),
    (
        "Custom Commands",
        &[
            "Run Custom Command",
            "Keystroke Sequence",
            "Create Custom Command",
        ],
    ),
];

fn action_submenu(app: &AppHandle, family: &str, actions: &[&str]) -> tauri::Result<Submenu<Wry>> {
    let mut builder = SubmenuBuilder::new(app, family);
    for action in actions {
        builder = builder.text(format!("action|{family}|{action}"), action);
    }
    builder.build()
}

pub fn build(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let settings = MenuItemBuilder::with_id("nav|general", "Settings…")
        .accelerator("CmdOrCtrl+,")
        .build(app)?;
    let open_hud = MenuItemBuilder::with_id("hud|open", "Open Immersive HUD")
        .accelerator("CmdOrCtrl+Shift+Space")
        .build(app)?;
    let save = MenuItemBuilder::with_id("state|save", "Save Settings")
        .accelerator("CmdOrCtrl+S")
        .build(app)?;

    let app_menu = SubmenuBuilder::new(app, "Rota")
        .about(None)
        .separator()
        .item(&settings)
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .separator()
        .quit()
        .build()?;

    let file_menu = SubmenuBuilder::new(app, "File")
        .item(&save)
        .separator()
        .close_window()
        .build()?;

    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;

    let mut actions_menu = SubmenuBuilder::new(app, "Actions");
    for (family, actions) in ACTION_FAMILIES {
        actions_menu = actions_menu.item(&action_submenu(app, family, actions)?);
    }
    let actions_menu = actions_menu.build()?;

    let hud_menu = SubmenuBuilder::new(app, "HUD")
        .item(&open_hud)
        .separator()
        .text("nav|hud", "HUD Studio")
        .text("nav|calibration", "Gesture Calibration")
        .text("nav|commands", "Custom Commands")
        .text("nav|overrides", "App Overrides")
        .build()?;

    let window_menu = SubmenuBuilder::new(app, "Window")
        .minimize()
        .maximize()
        .fullscreen()
        .separator()
        .close_window()
        .separator()
        .bring_all_to_front()
        .build()?;

    let help_menu = SubmenuBuilder::new(app, "Help")
        .text("nav|general", "Rota Help & Agent Access")
        .build()?;

    MenuBuilder::new(app)
        .item(&app_menu)
        .item(&file_menu)
        .item(&edit_menu)
        .item(&actions_menu)
        .item(&hud_menu)
        .item(&window_menu)
        .item(&help_menu)
        .build()
}
