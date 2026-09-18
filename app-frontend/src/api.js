// All calls are relative: the browser hits the same origin, NGINX (in the frontend pod)
// forwards /api to the Apache reverse-proxy tier, which forwards to FastAPI.
const BASE = "/api/v1";

async function request(path, options = {}) {
  const res = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = typeof body.detail === "string" ? body.detail : res.statusText;
    throw new Error(`${res.status}: ${detail}`);
  }
  return body;
}

export const api = {
  info: () => request("/info"),
  stats: () => request("/stats"),
  products: () => request("/products"),
  createProduct: (p) => request("/products", { method: "POST", body: JSON.stringify(p) }),
  createOrder: (o) => request("/orders", { method: "POST", body: JSON.stringify(o) }),
  orders: () => request("/orders?limit=10"),
};

export const money = (cents) =>
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(cents / 100);
