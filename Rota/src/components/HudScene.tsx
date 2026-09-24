import { useEffect, useMemo, useRef, useState } from "react";
import * as THREE from "three";
import type { HudDirection, HudLayer } from "../types";

interface HudSceneProps {
  layer: HudLayer;
  layerIndex: number;
  layerCount: number;
  animate: boolean;
  onNavigate: (direction: HudDirection) => void;
  onSelect?: (index: number) => void;
}

const directionFromDelta = (x: number, y: number): HudDirection =>
  Math.abs(x) > Math.abs(y) ? (x < 0 ? "left" : "right") : (y < 0 ? "up" : "down");

export function HudScene({ layer, layerIndex, layerCount, animate, onNavigate, onSelect }: HudSceneProps) {
  const host = useRef<HTMLDivElement>(null);
  const sceneApi = useRef<{ group: THREE.Group; target: THREE.Quaternion; velocity: THREE.Vector2 } | null>(null);
  const drag = useRef({ active: false, x: 0, y: 0, lastX: 0, lastY: 0, hold: 0 as number | undefined });
  const [selected, setSelected] = useState<number | null>(null);
  const [deep, setDeep] = useState(false);
  const selectedRef = useRef<number | null>(null);
  const deepRef = useRef(false);
  const reducedMotion = useMemo(() => window.matchMedia("(prefers-reduced-motion: reduce)").matches, []);

  useEffect(() => { selectedRef.current = selected; }, [selected]);
  useEffect(() => { deepRef.current = deep; }, [deep]);

  useEffect(() => {
    const element = host.current;
    if (!element) return;

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 100);
    camera.position.set(0, 0, 8.7);
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: "high-performance" });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setClearColor(0x000000, 0);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    element.appendChild(renderer.domElement);

    const root = new THREE.Group();
    root.rotation.x = -0.1;
    scene.add(root);
    const rim = new THREE.Mesh(
      new THREE.RingGeometry(2.33, 2.39, 128),
      new THREE.MeshBasicMaterial({ color: layer.accent, transparent: true, opacity: 0.34, side: THREE.DoubleSide })
    );
    root.add(rim);

    const count = Math.max(2, layer.slots);
    const sectors: THREE.Mesh[] = [];
    for (let index = 0; index < count; index += 1) {
      const start = Math.PI / 2 + index * (Math.PI * 2 / count) + 0.025;
      const geometry = new THREE.RingGeometry(0.72, 2.25, 48, 1, start, Math.PI * 2 / count - 0.05);
      const material = new THREE.MeshPhysicalMaterial({
        color: new THREE.Color(index % 2 ? "#172426" : "#1d2d2e"),
        emissive: new THREE.Color(layer.accent), emissiveIntensity: 0.025,
        roughness: 0.18, metalness: 0.38, transparent: true, opacity: 0.94,
        side: THREE.DoubleSide, clearcoat: 1, clearcoatRoughness: 0.17
      });
      const mesh = new THREE.Mesh(geometry, material);
      mesh.userData.index = index;
      mesh.position.z = index % 2 ? 0.005 : 0;
      sectors.push(mesh);
      root.add(mesh);
    }

    const center = new THREE.Mesh(
      new THREE.CircleGeometry(0.62, 64),
      new THREE.MeshPhysicalMaterial({ color: "#111716", emissive: layer.accent, emissiveIntensity: 0.08, roughness: 0.2, metalness: 0.6 })
    );
    center.position.z = 0.035;
    root.add(center);

    const glow = new THREE.PointLight(layer.accent, 8, 12, 2);
    glow.position.set(-1.5, 1.4, 3.5);
    scene.add(glow);
    scene.add(new THREE.AmbientLight(0xffffff, 1.8));

    const api = { group: root, target: new THREE.Quaternion(), velocity: new THREE.Vector2() };
    sceneApi.current = api;
    const resize = () => {
      const { width, height } = element.getBoundingClientRect();
      renderer.setSize(width, height, false);
      camera.aspect = width / Math.max(1, height);
      camera.updateProjectionMatrix();
    };
    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(element);

    let frame = 0;
    const timer = new THREE.Timer();
    timer.connect(document);
    const tick = (timestamp: number) => {
      timer.update(timestamp);
      const dt = Math.min(timer.getDelta(), 1 / 24);
      if (!reducedMotion && animate) {
        root.rotation.y += api.velocity.x * dt;
        root.rotation.x += api.velocity.y * dt;
        api.velocity.multiplyScalar(Math.pow(0.0008, dt));
        root.quaternion.slerp(api.target, 1 - Math.pow(0.00008, dt));
      } else {
        root.quaternion.copy(api.target);
      }
      sectors.forEach((sector, index) => {
        const material = sector.material as THREE.MeshPhysicalMaterial;
        const active = selectedRef.current === index;
        material.color.set(active ? layer.accent : index % 2 ? "#172426" : "#1d2d2e");
        material.emissiveIntensity = active ? 0.34 : 0.025;
        sector.position.z += ((active ? 0.12 : index % 2 ? 0.005 : 0) - sector.position.z) * 0.2;
      });
      root.scale.lerp(new THREE.Vector3(deepRef.current ? 0.92 : 1, deepRef.current ? 0.92 : 1, 1), 0.16);
      renderer.render(scene, camera);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(frame);
      timer.dispose();
      observer.disconnect();
      renderer.dispose();
      scene.traverse(object => {
        if (object instanceof THREE.Mesh) {
          object.geometry.dispose();
          const materials = Array.isArray(object.material) ? object.material : [object.material];
          materials.forEach(material => material.dispose());
        }
      });
      renderer.domElement.remove();
      sceneApi.current = null;
    };
  }, [layer.id, layer.slots, layer.accent, animate, reducedMotion]);

  useEffect(() => {
    const api = sceneApi.current;
    if (!api) return;
    const angle = (layerIndex / Math.max(1, layerCount)) * Math.PI * 2;
    api.target.setFromEuler(new THREE.Euler(-0.1, Math.sin(angle) * 0.08, -angle * 0.04));
  }, [layerIndex, layerCount]);

  const selectFromPoint = (clientX: number, clientY: number) => {
    const bounds = host.current?.getBoundingClientRect();
    if (!bounds) return;
    const x = clientX - bounds.left - bounds.width / 2;
    const y = clientY - bounds.top - bounds.height / 2;
    const radius = Math.hypot(x, y);
    if (radius < bounds.width * 0.09 || radius > bounds.width * 0.42) {
      setSelected(null);
      return;
    }
    const angle = (Math.atan2(-y, x) + Math.PI * 2) % (Math.PI * 2);
    setSelected(Math.floor(((angle + Math.PI / layer.slots) % (Math.PI * 2)) / (Math.PI * 2 / layer.slots)));
  };

  const pointerDown = (event: React.PointerEvent) => {
    event.currentTarget.setPointerCapture(event.pointerId);
    drag.current = { active: true, x: event.clientX, y: event.clientY, lastX: event.clientX, lastY: event.clientY, hold: window.setTimeout(() => setDeep(true), 420) };
    selectFromPoint(event.clientX, event.clientY);
  };
  const pointerMove = (event: React.PointerEvent) => {
    if (!drag.current.active) return;
    const dx = event.clientX - drag.current.lastX;
    const dy = event.clientY - drag.current.lastY;
    drag.current.lastX = event.clientX;
    drag.current.lastY = event.clientY;
    if (Math.hypot(event.clientX - drag.current.x, event.clientY - drag.current.y) > 8) window.clearTimeout(drag.current.hold);
    const api = sceneApi.current;
    if (api) {
      api.group.rotation.y += dx * 0.006;
      api.group.rotation.x += dy * 0.006;
      api.velocity.set(dx * 0.8, dy * 0.8);
    }
    selectFromPoint(event.clientX, event.clientY);
  };
  const pointerUp = (event: React.PointerEvent) => {
    if (!drag.current.active) return;
    window.clearTimeout(drag.current.hold);
    const dx = event.clientX - drag.current.x;
    const dy = event.clientY - drag.current.y;
    drag.current.active = false;
    setDeep(false);
    if (Math.hypot(dx, dy) > 44) {
      onNavigate(directionFromDelta(dx, dy));
    } else if (selected !== null) {
      onSelect?.(selected);
    }
  };

  return (
    <div className="hud-scene" ref={host} onPointerDown={pointerDown} onPointerMove={pointerMove} onPointerUp={pointerUp} onPointerCancel={pointerUp}>
      <div className="hud-orbit" aria-hidden="true"><span>{layerIndex + 1}</span> / {layerCount}</div>
      <div className="hud-center-copy" aria-live="polite">
        <strong>ROTA</strong><span>{deep ? "DEEP LAYER" : layer.name}</span>
      </div>
      <div className={`hud-labels ${deep ? "is-deep" : ""}`}>
        {layer.tiles.slice(0, layer.slots).map((tile, index) => {
          const angle = index / layer.slots * Math.PI * 2;
          const radius = deep ? 43 : 38;
          return <button key={tile.id} className={selected === index ? "active" : ""}
            style={{ left: `${50 + Math.cos(angle) * radius}%`, top: `${50 - Math.sin(angle) * radius}%` }}
            onClick={event => { event.stopPropagation(); onSelect?.(index); }}>
            <i>{tile.icon}</i><span>{tile.label}</span>
          </button>;
        })}
      </div>
      {deep && selected !== null && layer.tiles[selected]?.children?.length ? <div className="deep-fan" aria-label={`Deep options for ${layer.tiles[selected].label}`}>
        {layer.tiles[selected].children!.map((child, index, children) => {
          const origin = selected / layer.slots * Math.PI * 2;
          const angle = origin + (index - (children.length - 1) / 2) * 0.22;
          return <button key={child.id} style={{ left: `${50 + Math.cos(angle) * 46}%`, top: `${50 - Math.sin(angle) * 46}%` }} onClick={event => { event.stopPropagation(); onSelect?.(selected); }}><i>{child.icon}</i><span>{child.label}</span></button>;
        })}
      </div> : null}
      <div className="hud-swipe-hint">SWIPE · HOLD FOR DEPTH</div>
    </div>
  );
}
