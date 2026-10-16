# Action editing and manual sync

## Website bookmark titles

In the shared action picker, choose **Open a website** and fill in **Website title (optional)** and **Website address**. The title becomes the displayed action name. An empty title falls back to the URL. Reopening an existing website action restores its saved title and address; changing either keeps an explicitly selected browser. Changes are drafts until **Use action** is pressed; Cancel leaves the assignment untouched.

## Sync settings action

Search for **Sync settings** in the action picker or launcher. Assign it like any other action. It uses the same explicit save/publish operation as the **Sync settings** button under **Sync & backup**: save the current configuration locally and, when signed in, publish it to that account using revision checks. Signed-out saves remain local. This action does not restore or merge a remote configuration and does not upload encrypted API keys. Startup still restores only the saved login, not the settings themselves.

## Launcher confirmation

One press of Return confirms and runs the selected type-to-find action or app-menu item. There is no extra second-Return stage. Speech updates are stopped before selection is executed, and registered-action/menu identity checks remain in place.
