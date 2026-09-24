import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, Layers, Plus } from "lucide-react";
import type { HudDirection, Profile } from "../types";

const directions = [
  { id: "up", label: "Above", hint: "Swipe up", icon: ArrowUp },
  { id: "left", label: "Left", hint: "Swipe left", icon: ArrowLeft },
  { id: "right", label: "Right", hint: "Swipe right", icon: ArrowRight },
  { id: "down", label: "Below", hint: "Swipe down", icon: ArrowDown }
] as const;

interface LayerMapProps {
  profile: Profile;
  selectedLayerId: string;
  selectLayer: (id: string) => void;
  addLayer: (direction: HudDirection) => void;
  moveLayer: (id: string, direction: HudDirection) => void;
}

export function LayerMap({ profile, selectedLayerId, selectLayer, addLayer, moveLayer }: LayerMapProps) {
  const main = profile.layers.find(item => item.id === "main") ?? profile.layers[0];
  const directional = profile.layers.filter(item => item.id !== main.id);
  const openDirection = directions.find(direction => !directional.some(item => item.position === direction.id));

  return <section className="layer-map-panel">
    <header>
      <div><span>LAYER ORBIT</span><h2>Build around your Main HUD</h2><p>Click an empty direction to add a layer. Its position becomes the swipe that opens it.</p></div>
      <button className="primary" disabled={!openDirection} onClick={() => openDirection && addLayer(openDirection.id)}><Plus size={15}/> Add HUD layer</button>
    </header>
    <div className="layer-map-canvas">
      {directions.map(({ id, label, hint, icon: Icon }) => {
        const item = directional.find(candidate => candidate.position === id);
        if (!item) return <button key={id} className={`layer-drop-zone direction-${id}`} onClick={() => addLayer(id)}><Icon size={20}/><strong>Add layer</strong><span>{label} · {hint}</span></button>;
        const number = profile.layers.findIndex(candidate => candidate.id === item.id) + 1;
        return <article key={id} className={`layer-map-card direction-${id} ${selectedLayerId === item.id ? "selected" : ""}`}>
          <button className="layer-card-main" onClick={() => selectLayer(item.id)}><i style={{ background: item.accent }}/><span className="layer-number">{String(number).padStart(2, "0")}</span><strong>{item.name}</strong><small>{item.slots} tile slots</small><em>{item.shortcut || "No hotkey"}</em></button>
          <footer><button onClick={() => selectLayer(item.id)}>Edit layer</button><label><span className="sr-only">Direction</span><select value={item.position} onChange={event => moveLayer(item.id, event.target.value as HudDirection)}>{directions.map(direction => <option key={direction.id} value={direction.id}>{direction.label}</option>)}</select></label></footer>
        </article>;
      })}
      <article className={`layer-map-card main-layer ${selectedLayerId === main.id ? "selected" : ""}`}>
        <button className="layer-card-main" onClick={() => selectLayer(main.id)}><i style={{ background: main.accent }}/><span className="layer-number">01</span><strong>{main.name}</strong><small>{main.slots} tile slots · fixed center</small><em>{main.shortcut || "Main HUD actions"}</em></button>
        <footer><span><Layers size={13}/> Main layer</span><button onClick={() => selectLayer(main.id)}>Edit layer</button></footer>
      </article>
    </div>
  </section>;
}
