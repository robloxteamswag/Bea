// Vercel Edge relay for Google Drive videos — the cloud twin of server.ps1's
// /drive/<id>. Drive serves downloads as "generic file, never sniff", which
// browsers refuse to play; relabel the stream as video and pass ranges through.
export const config = { runtime: "edge" };

export default async function handler(req) {
  const m = new URL(req.url).pathname.match(/\/api\/drive\/([A-Za-z0-9_-]{20,})$/);
  if (!m) return new Response("bad id", { status: 400 });
  const headers = {};
  const range = req.headers.get("range");
  if (range) headers.Range = range;
  const r = await fetch(
    `https://drive.usercontent.google.com/download?id=${m[1]}&export=download&confirm=t`,
    { headers }
  );
  if ((r.headers.get("content-type") || "").includes("text/html")) {
    return new Response("drive returned a page, not a video", { status: 502 });
  }
  const h = new Headers();
  h.set("Content-Type", "video/mp4");
  h.set("Accept-Ranges", "bytes");
  for (const k of ["content-range", "content-length"]) {
    const v = r.headers.get(k);
    if (v) h.set(k, v);
  }
  return new Response(r.body, { status: r.status === 206 ? 206 : 200, headers: h });
}
