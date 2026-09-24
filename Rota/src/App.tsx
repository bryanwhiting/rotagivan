import { useEffect, useMemo, useRef, useState } from "react";
import {
  Activity, AppWindow, Bluetooth, ChevronDown, Command, Crosshair, Database,
  Gauge, Grid3X3, Keyboard, MonitorUp, MousePointer2, Plus, Power, Radio,
  RefreshCw, Rotate3D, Save, Settings2, SlidersHorizontal, Sparkles, Trash2
} from "lucide-react";
import { createDefaultState, createProfile } from "./defaults";
import { getBackendStatus, loadState, nativeAction, saveState } from "./lib/backend";
import { HudScene } from "./components/HudScene";
import { ACTION_CATEGORIES, actionCategoryFor, canonicalAction } from "./actionCatalog";
import type { BackendStatus, HudDirection, HudLayer, Profile, RotaMacro, RotaState, SectionId, Tile } from "./types";

const sections: { id: SectionId; label: string; eyebrow: string; icon: typeof Grid3X3 }[] = [
  { id: "devices", label: "Devices", eyebrow: "Input", icon: Bluetooth },
  { id: "hud", label: "HUD Studio", eyebrow: "Spatial", icon: Rotate3D },
  { id: "calibration", label: "Calibration", eyebrow: "Gesture", icon: Crosshair },
  { id: "commands", label: "Custom Commands", eyebrow: "Compose", icon: Keyboard },
  { id: "overrides", label: "App Overrides", eyebrow: "Context", icon: AppWindow },
  { id: "pointer", label: "Pointer & Scroll", eyebrow: "Motion", icon: MousePointer2 },
  { id: "general", label: "General", eyebrow: "System", icon: Settings2 }
];

const clone = <T,>(value: T): T => structuredClone(value);

function normalizeActionCatalog(state: RotaState) {
  const next = clone(state);
  const normalizeTiles = (tiles: Tile[]) => tiles.forEach(tile => {
    tile.action = canonicalAction(tile.action);
    if (tile.children) normalizeTiles(tile.children);
  });
  next.profiles.forEach(profile => profile.layers.forEach(layer => normalizeTiles(layer.tiles)));
  next.overrides.forEach(item => { item.action = canonicalAction(item.action); });
  return next;
}

function Toggle({ checked, onChange, label, detail }: { checked: boolean; onChange: (value: boolean) => void; label: string; detail?: string }) {
  return <label className="toggle-row"><span><strong>{label}</strong>{detail && <small>{detail}</small>}</span><button type="button" role="switch" aria-checked={checked} className={`switch ${checked ? "on" : ""}`} onClick={() => onChange(!checked)}><i /></button></label>;
}

function Range({ label, value, min = 0, max = 100, unit = "%", onChange }: { label: string; value: number; min?: number; max?: number; unit?: string; onChange: (value: number) => void }) {
  return <label className="range-row"><span>{label}</span><input type="range" min={min} max={max} value={value} onChange={event => onChange(Number(event.target.value))} /><output>{value}{unit}</output></label>;
}

function Card({ title, icon: Icon, children, className = "" }: { title: string; icon: typeof Grid3X3; children: React.ReactNode; className?: string }) {
  return <section className={`card ${className}`}><header><Icon size={17} /><h3>{title}</h3></header><div className="card-body">{children}</div></section>;
}

function ActionSelect({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  const known = actionCategoryFor(value);
  return <select value={value} onChange={event => onChange(event.target.value)}>
    {!known && value && value !== "Unassigned" && <option value={value}>{value} · Legacy</option>}
    <option value="Unassigned">Unassigned</option>
    {ACTION_CATEGORIES.map(category => <optgroup key={category.id} label={category.label}>{category.actions.map(action => <option key={action.label} value={action.label}>{action.label}</option>)}</optgroup>)}
  </select>;
}

function ActionHierarchy() {
  return <section className="action-hierarchy" aria-label="Action hierarchy"><header><span>ACTION HIERARCHY</span><strong>Choose a family, then an action</strong><p>Every HUD tile and gesture follows the same six-part structure.</p></header><div>{ACTION_CATEGORIES.map((category, index) => <article key={category.id}><i>{String(index + 1).padStart(2, "0")}</i><b>{category.glyph}</b><span><strong>{category.label}</strong><small>{category.description}</small></span><em>{category.actions.length}</em></article>)}</div></section>;
}

function MotionGraph({ speed, acceleration, color }: { speed: number; acceleration: number; color: string }) {
  const points = Array.from({ length: 25 }, (_, index) => {
    const x = index / 24;
    const y = Math.min(1, x * (speed / 52) * Math.pow(1 + x * 1.8, (acceleration - 50) / 45));
    return `${x * 300},${108 - y * 92}`;
  }).join(" ");
  return <svg className="motion-graph" viewBox="0 0 300 120" role="img" aria-label="Motion response curve">
    <defs><linearGradient id={`fill-${color.slice(1)}`} x1="0" y1="0" x2="0" y2="1"><stop stopColor={color} stopOpacity=".36"/><stop offset="1" stopColor={color} stopOpacity="0"/></linearGradient></defs>
    {[30, 60, 90].map(y => <line key={y} x1="0" y1={y} x2="300" y2={y} />)}
    <polygon points={`0,108 ${points} 300,108`} fill={`url(#fill-${color.slice(1)})`} />
    <polyline points={points} style={{ stroke: color }} />
  </svg>;
}

export function App() {
  const [state, setState] = useState<RotaState>(() => createDefaultState());
  const [ready, setReady] = useState(false);
  const [section, setSection] = useState<SectionId>("hud");
  const [hudOpen, setHudOpen] = useState(false);
  const [selectedLayerId, setSelectedLayerId] = useState("main");
  const [status, setStatus] = useState<BackendStatus | null>(null);
  const [toast, setToast] = useState("");
  const lastSaved = useRef("");

  useEffect(() => {
    Promise.all([loadState(), getBackendStatus()]).then(([saved, backend]) => {
      const value = normalizeActionCatalog(saved ?? createDefaultState());
      setState(value); setStatus(backend); setReady(true);
      lastSaved.current = JSON.stringify(value);
      if (!saved || JSON.stringify(saved) !== lastSaved.current) void saveState(value);
    });
  }, []);

  useEffect(() => {
    if (!ready) return;
    const serialized = JSON.stringify(state);
    if (serialized === lastSaved.current) return;
    const timer = window.setTimeout(() => {
      void saveState(state).then(() => { lastSaved.current = serialized; });
    }, 220);
    return () => window.clearTimeout(timer);
  }, [state, ready]);

  useEffect(() => {
    if (!ready) return;
    const interval = window.setInterval(() => {
      void loadState().then(external => {
        if (!external) return;
        const serialized = JSON.stringify(external);
        if (serialized !== lastSaved.current) {
          lastSaved.current = serialized;
          setState(external);
          setToast("Settings updated by MCP");
        }
      });
    }, 2000);
    return () => window.clearInterval(interval);
  }, [ready]);

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(""), 2200);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const profileIndex = Math.max(0, state.profiles.findIndex(profile => profile.id === state.activeProfileId));
  const profile = state.profiles[profileIndex] ?? state.profiles[0];
  const layerIndex = Math.max(0, profile.layers.findIndex(layer => layer.id === selectedLayerId));
  const layer = profile.layers[layerIndex] ?? profile.layers[0];

  const update = (recipe: (draft: RotaState) => void) => setState(current => { const next = clone(current); recipe(next); return next; });
  const updateProfile = (recipe: (profile: Profile) => void) => update(draft => recipe(draft.profiles[profileIndex]));
  const updateLayer = (recipe: (layer: HudLayer) => void) => updateProfile(draft => recipe(draft.layers[layerIndex]));
  const notify = (message: string) => setToast(message);

  const navigateHud = (direction: HudDirection) => {
    const positioned = profile.layers.findIndex(candidate => candidate.position === direction && candidate.id !== layer.id);
    const forward = direction === "left" || direction === "up";
    const next = positioned >= 0 ? positioned : (layerIndex + (forward ? 1 : -1) + profile.layers.length) % profile.layers.length;
    setSelectedLayerId(profile.layers[next].id);
    update(draft => { draft.activeLayerId = profile.layers[next].id; });
  };

  const addProfile = () => update(draft => {
    const fresh = createProfile(`Profile ${draft.profiles.length + 1}`);
    draft.profiles.push(fresh); draft.activeProfileId = fresh.id;
  });

  if (!ready || !profile || !layer) return <div className="boot"><Rotate3D /><span>ROTA</span><i /></div>;

  return <div className="app-shell">
    <aside className="sidebar">
      <div className="brand"><div className="brand-mark"><span>R</span><i /></div><div><strong>ROTA</strong><small>SPATIAL CONTROL</small></div></div>
      <div className="profile-block"><span>ACTIVE PROFILE</span><div className="select-wrap"><select value={state.activeProfileId} onChange={event => update(draft => { draft.activeProfileId = event.target.value; draft.activeLayerId = "main"; })}>{state.profiles.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select><ChevronDown size={14}/></div></div>
      <nav>{sections.map(item => { const Icon = item.icon; return <button key={item.id} className={section === item.id ? "active" : ""} onClick={() => setSection(item.id)}><Icon size={18}/><span><small>{item.eyebrow}</small>{item.label}</span></button>; })}</nav>
      <div className="sidebar-foot"><span className={`status-light ${state.enabled ? "live" : ""}`} /><div><strong>{state.enabled ? "Rota is active" : "Rota is paused"}</strong><small>{status?.nativeInput ?? "Loading engine"}</small></div><button onClick={() => update(draft => { draft.enabled = !draft.enabled; })}><Power size={16}/></button></div>
    </aside>

    <main>
      <header className="topbar"><div><span>{sections.find(item => item.id === section)?.eyebrow}</span><h1>{sections.find(item => item.id === section)?.label}</h1></div><div className="top-actions"><button className="ghost" onClick={() => setHudOpen(true)}><Rotate3D size={16}/> Open HUD</button><button className="primary" onClick={() => { void saveState(state); notify("Settings saved"); }}><Save size={15}/> Saved</button></div></header>
      <div className="page-scroll">
        {section === "devices" && <DevicesPage state={state} update={update} notify={notify} />}
        {section === "hud" && <HudPage state={state} profile={profile} layer={layer} layerIndex={layerIndex} selectLayer={setSelectedLayerId} update={update} updateLayer={updateLayer} navigate={navigateHud} open={() => setHudOpen(true)} />}
        {section === "calibration" && <CalibrationPage profile={profile} update={updateProfile} />}
        {section === "commands" && <CustomCommandsPage state={state} update={update} />}
        {section === "overrides" && <OverridesPage state={state} update={update} />}
        {section === "pointer" && <PointerPage profile={profile} update={updateProfile} />}
        {section === "general" && <GeneralPage state={state} status={status} update={update} addProfile={addProfile} notify={notify} />}
      </div>
    </main>

    {hudOpen && <div className="hud-overlay" role="dialog" aria-modal="true" aria-label="Rota HUD"><button className="hud-close" onClick={() => setHudOpen(false)}>ESC · CLOSE</button><HudScene layer={layer} layerIndex={layerIndex} layerCount={profile.layers.length} animate={state.hudAnimations} onNavigate={navigateHud} onSelect={index => notify(layer.tiles[index]?.label ?? "Empty slot")} /></div>}
    {toast && <div className="toast"><Sparkles size={15}/>{toast}</div>}
  </div>;
}

function DevicesPage({ state, update, notify }: { state: RotaState; update: (recipe: (draft: RotaState) => void) => void; notify: (message: string) => void }) {
  return <div className="page two-up">
    <Card title="ZSA Navigator" icon={MousePointer2}><div className="device-hero"><span className="device-glyph navigator"><i/><i/></span><div><strong>Navigator</strong><small>{state.navigatorEnabled ? "Connected · 125 Hz" : "Driver released"}</small></div></div><Toggle checked={state.navigatorEnabled} onChange={value => update(draft => { draft.navigatorEnabled = value; })} label="Use ZSA Navigator" detail="Pointer, scroll, actions, layers and HUD"/><button className="wide-action" onClick={() => { void nativeAction("reconnect").then(notify); }}><RefreshCw size={15}/> Reconnect device</button></Card>
    <Card title="Apple Trackpad" icon={MonitorUp}><div className="device-hero"><span className="device-glyph trackpad"><i/></span><div><strong>Built-in & Magic</strong><small>{state.appleInputAllowed ? "Raw gestures allowed" : "Permission required"}</small></div></div><Toggle checked={state.appleEnabled} onChange={value => update(draft => { draft.appleEnabled = value; })} label="Use Apple actions" detail="Native pointer and scrolling remain macOS-owned"/><Toggle checked={state.appleInputAllowed} onChange={value => update(draft => { draft.appleInputAllowed = value; })} label="Allow input on this Mac" detail="Experimental local opt-in"/></Card>
    <Card title="Action routing" icon={Radio} className="span-two"><Toggle checked={state.shareActions} onChange={value => update(draft => { draft.shareActions = value; })} label="Share tap and swipe actions" detail="One gesture map across both devices"/><div className="route-map"><span>TRACKPAD</span><i/><b>ACTIVE PROFILE</b><i/><span>HUD / ACTION</span></div></Card>
  </div>;
}

function HudPage({ state, profile, layer, layerIndex, selectLayer, update, updateLayer, navigate, open }: { state: RotaState; profile: Profile; layer: HudLayer; layerIndex: number; selectLayer: (id: string) => void; update: (recipe: (draft: RotaState) => void) => void; updateLayer: (recipe: (layer: HudLayer) => void) => void; navigate: (direction: HudDirection) => void; open: () => void }) {
  const [selectedTile, setSelectedTile] = useState(0);
  const selected = layer.tiles[selectedTile];
  const addLayer = () => update(draft => {
    const current = draft.profiles.find(item => item.id === profile.id)!;
    const newLayer: HudLayer = { id: crypto.randomUUID(), name: `Layer ${current.layers.length + 1}`, position: "right", slots: 6, accent: "#9fe870", shortcut: "", tiles: [] };
    current.layers.push(newLayer);
  });
  const setSlots = (slots: number) => updateLayer(draft => {
    draft.slots = slots;
    while (draft.tiles.length < slots) draft.tiles.push({ id: crypto.randomUUID(), label: "Empty", icon: "+", action: "Unassigned" });
    draft.tiles = draft.tiles.slice(0, slots);
  });
  return <div className="page hud-studio">
    <section className="hud-preview-card"><div className="hud-preview-toolbar"><div><span>LIVE THREE.JS PREVIEW</span><strong>{layer.name}</strong></div><button onClick={open}><Rotate3D size={15}/> Immersive</button></div><HudScene layer={layer} layerIndex={layerIndex} layerCount={profile.layers.length} animate={state.hudAnimations} onNavigate={navigate} /></section>
    <section className="inspector"><div className="layer-tabs"><div>{profile.layers.map(item => <button key={item.id} className={item.id === layer.id ? "active" : ""} onClick={() => selectLayer(item.id)}>{item.name}</button>)}</div><button onClick={addLayer}><Plus size={14}/></button></div>
      <Card title="Layer geometry" icon={Grid3X3}><label className="field"><span>Name</span><input value={layer.name} onChange={event => updateLayer(draft => { draft.name = event.target.value; })}/></label><div className="field split"><span>Direction</span><select value={layer.position} onChange={event => updateLayer(draft => { draft.position = event.target.value as HudDirection; })}>{["left","right","up","down"].map(value => <option key={value}>{value}</option>)}</select></div><Range label="Tile slots" value={layer.slots} min={2} max={16} unit="" onChange={setSlots}/><label className="field color-field"><span>Accent</span><input type="color" value={layer.accent} onChange={event => updateLayer(draft => { draft.accent = event.target.value; })}/><code>{layer.accent}</code></label></Card>
      <Card title="Surface & motion" icon={Sparkles}><div className="segmented">{(["graphite","starburst","air"] as const).map(theme => <button key={theme} className={state.hudTheme === theme ? "active" : ""} onClick={() => update(draft => { draft.hudTheme = theme; })}>{theme}</button>)}</div><Toggle checked={state.hudAnimations} onChange={value => update(draft => { draft.hudAnimations = value; })} label="Physics animation" detail="Quaternion rotation, inertia and depth"/></Card>
      {selected && <Card title={`Tile ${selectedTile + 1} assignment`} icon={Command}><label className="field"><span>Label</span><input value={selected.label} onChange={event => updateLayer(draft => { draft.tiles[selectedTile].label = event.target.value; })}/></label><label className="field"><span>Glyph</span><input value={selected.icon} onChange={event => updateLayer(draft => { draft.tiles[selectedTile].icon = event.target.value; })}/></label><label className="field"><span>Action</span><ActionSelect value={selected.action} onChange={value => updateLayer(draft => { draft.tiles[selectedTile].action = value; })}/></label>{actionCategoryFor(selected.action) && <div className="action-breadcrumb"><span>{actionCategoryFor(selected.action)?.glyph}</span>{actionCategoryFor(selected.action)?.label}<i>›</i><strong>{selected.action}</strong></div>}<label className="field"><span>Value</span><input value={selected.detail ?? ""} placeholder="App, URL, shortcut or command" onChange={event => updateLayer(draft => { draft.tiles[selectedTile].detail = event.target.value; })}/></label><button className="wide-action" onClick={() => updateLayer(draft => { const tile = draft.tiles[selectedTile]; tile.children = tile.children?.length ? undefined : [{ id: crypto.randomUUID(), label: "Deep option", icon: "↳", action: "Run Custom Command" }]; })}>{selected.children?.length ? "Remove deep layer" : "Add hold-for-depth layer"}</button></Card>}
    </section>
    <Card title={`Tiles · ${layer.slots} slots`} icon={Command} className="tile-editor"><div className="tile-grid">{Array.from({ length: layer.slots }, (_, index) => { const tile = layer.tiles[index]; return <button key={tile?.id ?? index} className={selectedTile === index ? "selected" : ""} onClick={() => setSelectedTile(index)}><b>{tile?.icon ?? "+"}</b><span>{tile?.label ?? "Empty"}</span><small>{tile?.children?.length ? `${tile.children.length} deep option · ${tile.action}` : tile?.action ?? "Click to assign"}</small></button>; })}</div></Card>
  </div>;
}

function CalibrationPage({ profile, update }: { profile: Profile; update: (recipe: (profile: Profile) => void) => void }) {
  const calibration = profile.calibration;
  return <div className="page"><div className="page-intro"><span>MEASURED, NOT GUESSED</span><h2>Gesture calibration</h2><p>Tune recognition windows without changing native pointer behavior.</p></div><div className="two-up"><Card title="Tap rhythm" icon={Activity}><Range label="Tap duration" value={calibration.tapDuration} min={80} max={400} unit=" ms" onChange={value => update(draft => { draft.calibration.tapDuration = value; })}/><Range label="Movement tolerance" value={calibration.tapMovement} min={4} max={60} unit="" onChange={value => update(draft => { draft.calibration.tapMovement = value; })}/><Range label="Double-tap delay" value={calibration.doubleTapDelay} min={120} max={500} unit=" ms" onChange={value => update(draft => { draft.calibration.doubleTapDelay = value; })}/></Card><Card title="Swipe intent" icon={Crosshair}><Range label="Travel distance" value={calibration.swipeDistance} min={30} max={180} unit="" onChange={value => update(draft => { draft.calibration.swipeDistance = value; })}/><Range label="Time window" value={calibration.swipeDuration} min={120} max={700} unit=" ms" onChange={value => update(draft => { draft.calibration.swipeDuration = value; })}/><div className="gesture-pad"><i/><span>SWIPE TO TEST</span></div></Card></div></div>;
}

function CustomCommandsPage({ state, update }: { state: RotaState; update: (recipe: (draft: RotaState) => void) => void }) {
  const [selected, setSelected] = useState(state.macros[0]?.id ?? "");
  const macro = state.macros.find(item => item.id === selected) ?? state.macros[0];
  const addCommand = () => update(draft => { const item: RotaMacro = { id: crypto.randomUUID(), name: "New command", shortcut: "", steps: [] }; draft.macros.push(item); setSelected(item.id); });
  return <div className="page macro-layout"><ActionHierarchy/><section className="macro-list"><header><span>CUSTOM COMMANDS</span><button aria-label="Add custom command" onClick={addCommand}><Plus size={15}/></button></header>{state.macros.map(item => <button key={item.id} className={macro?.id === item.id ? "active" : ""} onClick={() => setSelected(item.id)}><Command size={16}/><span><strong>{item.name}</strong><small>{item.steps.length} steps</small></span><kbd>{item.shortcut || "—"}</kbd></button>)}</section>{macro && <Card title="Command sequence" icon={Keyboard} className="macro-editor"><div className="form-row"><input aria-label="Command name" value={macro.name} onChange={event => update(draft => { draft.macros.find(item => item.id === macro.id)!.name = event.target.value; })}/><input aria-label="Command shortcut" className="shortcut" value={macro.shortcut} placeholder="Record shortcut" onChange={event => update(draft => { draft.macros.find(item => item.id === macro.id)!.shortcut = event.target.value; })}/></div><div className="steps">{macro.steps.map((step, index) => <div className="step" key={step.id}><i>{index + 1}</i><select value={step.type} onChange={event => update(draft => { draft.macros.find(item => item.id === macro.id)!.steps[index].type = event.target.value as typeof step.type; })}><option value="keys">Keys</option><option value="app">Open app</option><option value="delay">Delay</option></select><input value={step.value} onChange={event => update(draft => { draft.macros.find(item => item.id === macro.id)!.steps[index].value = event.target.value; })}/><label><input type="number" value={step.delay} onChange={event => update(draft => { draft.macros.find(item => item.id === macro.id)!.steps[index].delay = Number(event.target.value); })}/> ms</label></div>)}</div><button className="wide-action" onClick={() => update(draft => { draft.macros.find(item => item.id === macro.id)!.steps.push({ id: crypto.randomUUID(), type: "keys", value: "⌘ K", delay: 80 }); })}><Plus size={15}/> Add command step</button></Card>}</div>;
}

function OverridesPage({ state, update }: { state: RotaState; update: (recipe: (draft: RotaState) => void) => void }) {
  return <div className="page"><div className="page-intro"><span>CONTEXT ENGINE</span><h2>App overrides</h2><p>Change what a gesture means when a specific app is frontmost.</p><button className="primary" onClick={() => update(draft => { draft.overrides.push({ id: crypto.randomUUID(), app: "Choose app", detail: "New context", enabled: true, gesture: "Two-finger left", action: "Mission Control" }); })}><Plus size={15}/> Add override</button></div><div className="override-list">{state.overrides.map((item, index) => <Card key={item.id} title={item.app} icon={AppWindow}><Toggle checked={item.enabled} onChange={value => update(draft => { draft.overrides[index].enabled = value; })} label={item.detail}/><label className="field"><span>Gesture</span><input value={item.gesture} onChange={event => update(draft => { draft.overrides[index].gesture = event.target.value; })}/></label><label className="field"><span>Action</span><ActionSelect value={item.action} onChange={value => update(draft => { draft.overrides[index].action = value; })}/></label><button className="danger-link" onClick={() => update(draft => { draft.overrides.splice(index, 1); })}><Trash2 size={14}/> Remove</button></Card>)}</div></div>;
}

function PointerPage({ profile, update }: { profile: Profile; update: (recipe: (profile: Profile) => void) => void }) {
  const pointer = profile.pointer;
  return <div className="page two-up"><Card title="Pointer response" icon={MousePointer2}><MotionGraph speed={pointer.cursorSpeed} acceleration={pointer.cursorAcceleration} color="#9fe870"/><Range label="Speed" value={pointer.cursorSpeed} onChange={value => update(draft => { draft.pointer.cursorSpeed = value; })}/><Range label="Acceleration" value={pointer.cursorAcceleration} onChange={value => update(draft => { draft.pointer.cursorAcceleration = value; })}/><Range label="Smoothing" value={pointer.smoothing} onChange={value => update(draft => { draft.pointer.smoothing = value; })}/></Card><Card title="Scroll response" icon={SlidersHorizontal}><MotionGraph speed={pointer.scrollSpeed} acceleration={pointer.scrollAcceleration} color="#73b7ff"/><Range label="Speed" value={pointer.scrollSpeed} onChange={value => update(draft => { draft.pointer.scrollSpeed = value; })}/><Range label="Acceleration" value={pointer.scrollAcceleration} onChange={value => update(draft => { draft.pointer.scrollAcceleration = value; })}/><Range label="Coast" value={pointer.coast} onChange={value => update(draft => { draft.pointer.coast = value; })}/><Toggle checked={pointer.kinetic} onChange={value => update(draft => { draft.pointer.kinetic = value; })} label="After-scroll coasting"/><div className="check-pair"><Toggle checked={pointer.invertX} onChange={value => update(draft => { draft.pointer.invertX = value; })} label="Invert horizontal"/><Toggle checked={pointer.invertY} onChange={value => update(draft => { draft.pointer.invertY = value; })} label="Invert vertical"/></div></Card><Card title="Dragging" icon={Command} className="span-two"><Toggle checked={pointer.tapDrag} onChange={value => update(draft => { draft.pointer.tapDrag = value; })} label="Tap, then hold to drag" detail="Lift and reposition without dropping"/><Toggle checked={pointer.regrip} onChange={value => update(draft => { draft.pointer.regrip = value; })} label="Allow re-grip" detail="Keep the synthetic drag active during repositioning"/></Card></div>;
}

function GeneralPage({ state, status, update, addProfile, notify }: { state: RotaState; status: BackendStatus | null; update: (recipe: (draft: RotaState) => void) => void; addProfile: () => void; notify: (message: string) => void }) {
  return <div className="page two-up"><Card title="Rota engine" icon={Gauge}><div className="status-table"><span>Platform</span><b>{status?.platform ?? "—"}</b><span>Persistence</span><b>{status?.persistence ?? "—"}</b><span>Native input</span><b>{status?.nativeInput ?? "—"}</b></div><Toggle checked={state.enabled} onChange={value => update(draft => { draft.enabled = value; })} label="Enable Rota"/><Toggle checked={state.launchAtLogin} onChange={value => update(draft => { draft.launchAtLogin = value; })} label="Launch at login"/><button className="wide-action" onClick={() => void nativeAction("open-settings", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility").then(notify)}><Settings2 size={15}/> Accessibility settings</button></Card><Card title="Agent access · MCP" icon={Database}><div className="mcp-live"><i/><span><strong>Rota MCP server</strong><small>Streamable HTTP · local only</small></span></div><label className="endpoint"><span>ENDPOINT</span><code>{status?.mcpEndpoint ?? "Starting…"}</code></label><p className="fineprint">Agents can read and edit every Rota setting through atomic Rust-backed tools. Changes appear in this window automatically.</p><div className="tool-chips"><span>get_settings</span><span>set_setting</span><span>delete_setting</span><span>replace_settings</span></div></Card><Card title="Profiles" icon={Grid3X3} className="span-two"><div className="profile-grid">{state.profiles.map((profile, index) => <div key={profile.id}><i>{String(index + 1).padStart(2,"0")}</i><input value={profile.name} onChange={event => update(draft => { draft.profiles[index].name = event.target.value; })}/><span>{profile.layers.length} HUD layers</span></div>)}<button onClick={addProfile}><Plus size={18}/><span>Add profile</span></button></div></Card><Card title="Configuration sync" icon={RefreshCw} className="span-two"><Toggle checked={state.syncEnabled} onChange={value => update(draft => { draft.syncEnabled = value; })} label="Enable cloud sync" detail="Optional endpoint; local state remains authoritative"/><label className="field"><span>Endpoint</span><input value={state.syncEndpoint} placeholder="https://…" onChange={event => update(draft => { draft.syncEndpoint = event.target.value; })}/></label></Card></div>;
}
