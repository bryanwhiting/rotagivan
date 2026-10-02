const root = document.querySelector<HTMLElement>("[data-demo]");
if (root) {
  const title = root.querySelector<HTMLElement>("[data-window-title]")!;
  const kicker = root.querySelector<HTMLElement>("[data-window-kicker]")!;
  const heading = root.querySelector<HTMLElement>("[data-window-heading]")!;
  const copy = root.querySelector<HTMLElement>("[data-window-copy]")!;
  const status = root.querySelector<HTMLElement>("[data-status]")!;
  const desktop = root.querySelector<HTMLElement>(".demo-desktop")!;
  const buttons = [
    ...root.querySelectorAll<HTMLButtonElement>("[data-action]"),
  ];
  const tour = root.querySelector<HTMLButtonElement>("[data-tour]")!;
  const actions: Record<
    string,
    {
      title: string;
      kicker: string;
      heading: string;
      copy: string;
      status: string;
    }
  > = {
    focus: {
      title: "Focus workflow",
      kicker: "ONE COMMAND. YOUR WHOLE ROUTINE.",
      heading: "Back to the good part.",
      copy: "A saved macro can open your writing app and run your chosen shortcuts, in sequence.",
      status: "Demo: writing app opened · focus shortcut sent",
    },
    browser: {
      title: "Browser shortcuts",
      kicker: "THE RIGHT DESTINATION.",
      heading: "Straight to your next idea.",
      copy: "Keep your go-to URLs and bookmarks within reach. Pick a destination and open it in your chosen browser.",
      status: "Demo: project dashboard opened in browser",
    },
    windows: {
      title: "Window Manager",
      kicker: "MAKE ROOM FOR YOUR WORK.",
      heading: "Everything in its place.",
      copy: "Move and resize windows from the HUD. Get the view you need without dragging every edge.",
      status: "Demo: active window tiled to the left",
    },
    music: {
      title: "Media controls",
      kicker: "STAY IN YOUR RHYTHM.",
      heading: "Keep the soundtrack going.",
      copy: "Play, pause, skip, and adjust volume from your command wheel while your work stays front and center.",
      status: "Demo: playback toggled",
    },
    voice: {
      title: "Voice mode",
      kicker: "SAY IT. REVIEW IT. DO IT.",
      heading: "“Open my browser.”",
      copy: "Voice mode transcribes a command and suggests matching actions. Review and confirm your choice. Provider setup is required in the app.",
      status: "Demo: Browser suggested · no microphone used",
    },
    notes: {
      title: "Notes shortcut",
      kicker: "CATCH THE THOUGHT.",
      heading: "An idea worth keeping.",
      copy: "Assign your favorite notes app to a tile. Jump to it the moment an idea arrives.",
      status: "Demo: notes app opened",
    },
    work: {
      title: "Work profile",
      kicker: "A PLACE FOR EVERY CONTEXT.",
      heading: "Get into work mode.",
      copy: "Build a named profile with its own layers, actions, and shortcuts. Keep your work setup separate from everything else.",
      status: "Demo: Work profile preview selected",
    },
    apps: {
      title: "App Explorer",
      kicker: "YOUR APPS. WITHIN REACH.",
      heading: "Your next app is right here.",
      copy: "Organize favorite apps into HUD groups. Give your frequent destinations a familiar place on the wheel.",
      status: "Demo: favorite apps group opened",
    },
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  let playing = false;
  function stop() {
    clearTimeout(timer);
    playing = false;
    tour.textContent = "Play a workflow ▷";
    tour.setAttribute("aria-pressed", "false");
  }
  function select(key: string, automatic = false) {
    if (!automatic) stop();
    const action = actions[key];
    if (!action) return;
    title.textContent = action.title;
    kicker.textContent = action.kicker;
    heading.textContent = action.heading;
    copy.textContent = action.copy;
    status.textContent = action.status;
    desktop.dataset.mode = key;
    buttons.forEach((button) =>
      button.setAttribute(
        "aria-pressed",
        String(button.dataset.action === key),
      ),
    );
  }
  function reset() {
    stop();
    title.textContent = "Today's workspace";
    kicker.textContent = "LESS FRICTION. MORE FLOW.";
    heading.textContent = "A little less clicking. A lot more doing.";
    copy.textContent =
      "Choose a command on the wheel to see what happens next.";
    status.textContent = "Click a tile. Find your flow.";
    delete desktop.dataset.mode;
    buttons.forEach((button) => button.setAttribute("aria-pressed", "false"));
  }
  buttons.forEach((button) => {
    button.setAttribute("aria-pressed", "false");
    button.addEventListener("click", () => select(button.dataset.action!));
  });
  root.querySelector("[data-reset]")!.addEventListener("click", reset);
  root.addEventListener("keydown", (event) => {
    if (event.altKey || event.ctrlKey || event.metaKey) return;
    if (event.key === "Escape") {
      event.preventDefault();
      reset();
    }
    const index = Number(event.key) - 1;
    if (/^[1-8]$/.test(event.key)) {
      event.preventDefault();
      buttons[index].focus();
      select(buttons[index].dataset.action!);
    }
  });
  tour.setAttribute("aria-pressed", "false");
  tour.addEventListener("click", () => {
    if (playing) {
      stop();
      return;
    }
    playing = true;
    tour.textContent = "Stop workflow ■";
    tour.setAttribute("aria-pressed", "true");
    const steps = ["apps", "browser", "windows", "focus"];
    let step = 0;
    const next = () => {
      select(steps[step], true);
      status.textContent = `Step ${step + 1} of ${steps.length}: ${actions[steps[step]].status.replace("Demo: ", "")}`;
      step += 1;
      if (step < steps.length) timer = setTimeout(next, 2200);
      else {
        stop();
        status.textContent =
          "Workflow complete. Your workspace is ready. Replay or try another tile.";
      }
    };
    next();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stop();
  });
}
