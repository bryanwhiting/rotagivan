// Shared, memoised fetch of /latest.json (served by the Worker from R2).
// Every script on a page shares one request.
export type Manifest = {
  version: string;
  build: string;
  url: string;
  sha256: string;
  size?: number;
  minimumOS?: string;
  architectures?: string[];
  zip?: { url: string; sha256: string; size: number };
  signing?: "development" | "developer-id";
  notarized?: boolean;
  publishedAt?: string;
};

let pending: Promise<Manifest | null> | undefined;

export function getLatest(): Promise<Manifest | null> {
  pending ??= fetch("/latest.json", { cache: "no-cache" })
    .then((r) => (r.ok ? (r.json() as Promise<Manifest>) : null))
    .catch(() => null);
  return pending;
}

export function absoluteUrl(url: string): URL {
  return new URL(url, location.href);
}

export function fileName(url: string): string {
  return decodeURIComponent(absoluteUrl(url).pathname.split("/").pop() ?? "");
}

export function megabytes(bytes: number): string {
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

export function architectureLabel(architectures: string[]): string {
  return architectures
    .map((a) => (a === "arm64" ? "Apple silicon (arm64)" : a === "x86_64" ? "Intel (x86_64)" : a))
    .join(" + ");
}
