import { useCallback, useEffect, useState } from "react";
import { api, money } from "./api.js";

const EMPTY = { sku: "", name: "", price: "", stock: "" };

export default function App() {
  const [info, setInfo] = useState(null);
  const [stats, setStats] = useState(null);
  const [products, setProducts] = useState([]);
  const [orders, setOrders] = useState([]);
  const [form, setForm] = useState(EMPTY);
  const [email, setEmail] = useState("demo@cloudforge.dev");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const [i, s, p, o] = await Promise.all([
        api.info(),
        api.stats(),
        api.products(),
        api.orders(),
      ]);
      setInfo(i);
      setStats(s);
      setProducts(p);
      setOrders(o);
      setError("");
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function addProduct(e) {
    e.preventDefault();
    try {
      await api.createProduct({
        sku: form.sku,
        name: form.name,
        price_cents: Math.round(Number(form.price) * 100),
        stock: Number(form.stock || 0),
      });
      setForm(EMPTY);
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  }

  async function buy(product) {
    try {
      await api.createOrder({ product_id: product.id, quantity: 1, customer_email: email });
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <main>
      <header>
        <h1>CloudForge</h1>
        <span className="meta" data-testid="version">
          {info ? `${info.service} ${info.version} · ${info.environment}` : "connecting…"}
        </span>
      </header>

      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}

      <section className="tiles" aria-label="Stats">
        <Tile label="Products" value={stats?.products ?? "–"} />
        <Tile label="Orders" value={stats?.orders ?? "–"} />
        <Tile label="Revenue" value={stats ? money(stats.revenue_cents) : "–"} />
        <Tile label="Cache" value={stats ? (stats.cached ? "hit" : "miss") : "–"} />
      </section>

      <section>
        <h2>Catalog</h2>
        <label className="inline">
          Buyer email{" "}
          <input value={email} onChange={(e) => setEmail(e.target.value)} type="email" />
        </label>
        {loading ? (
          <p>Loading…</p>
        ) : products.length === 0 ? (
          <p>No products yet. Add one below.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>SKU</th>
                <th>Name</th>
                <th className="num">Price</th>
                <th className="num">Stock</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {products.map((p) => (
                <tr key={p.id}>
                  <td>{p.sku}</td>
                  <td>{p.name}</td>
                  <td className="num">{money(p.price_cents)}</td>
                  <td className="num">{p.stock}</td>
                  <td>
                    <button disabled={p.stock < 1} onClick={() => buy(p)}>
                      Buy 1
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section>
        <h2>Add product</h2>
        <form onSubmit={addProduct} className="grid">
          <input required placeholder="SKU" value={form.sku}
            onChange={(e) => setForm({ ...form, sku: e.target.value })} />
          <input required placeholder="Name" value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })} />
          <input required placeholder="Price (USD)" type="number" min="0" step="0.01"
            value={form.price} onChange={(e) => setForm({ ...form, price: e.target.value })} />
          <input placeholder="Stock" type="number" min="0" value={form.stock}
            onChange={(e) => setForm({ ...form, stock: e.target.value })} />
          <button type="submit">Create</button>
        </form>
      </section>

      <section>
        <h2>Recent orders</h2>
        <ul className="orders">
          {orders.map((o) => (
            <li key={o.id}>
              #{o.id} · product {o.product_id} × {o.quantity} · {money(o.total_cents)} ·{" "}
              {o.customer_email}
            </li>
          ))}
        </ul>
      </section>
    </main>
  );
}

function Tile({ label, value }) {
  return (
    <div className="tile">
      <div className="tile-label">{label}</div>
      <div className="tile-value">{value}</div>
    </div>
  );
}
