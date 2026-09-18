import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "./App.jsx";
import { money } from "./api.js";

const responses = {
  "/api/v1/info": { service: "cloudforge-api", version: "1.2.3", environment: "test" },
  "/api/v1/stats": { products: 1, orders: 0, revenue_cents: 0, cached: false },
  "/api/v1/products": [
    { id: 1, sku: "CF-1", name: "Forge Hammer", price_cents: 2500, stock: 3, description: "" },
  ],
  "/api/v1/orders?limit=10": [],
};

afterEach(() => vi.restoreAllMocks());

describe("App", () => {
  it("renders catalog and version from the API", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (url) => ({
      ok: true,
      json: async () => responses[url],
    }));
    render(<App />);
    expect(await screen.findByText("Forge Hammer")).toBeInTheDocument();
    expect(screen.getByTestId("version")).toHaveTextContent("1.2.3");
  });

  it("shows an error when the API is down", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: false,
      status: 503,
      statusText: "Service Unavailable",
      json: async () => ({}),
    });
    render(<App />);
    expect(await screen.findByRole("alert")).toHaveTextContent("503");
  });
});

describe("money", () => {
  it("formats cents", () => expect(money(1999)).toBe("$19.99"));
});
