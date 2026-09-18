// k6 load test — drives HPA scale-out and feeds the Grafana RED/business dashboards.
//   docker run --rm -i --network host grafana/k6 run - <scripts/load-test.js
//   BASE_URL=http://cloudforge.local k6 run scripts/load-test.js
import http from "k6/http";
import { check, sleep } from "k6";

const BASE = __ENV.BASE_URL || "http://cloudforge.local";

export const options = {
  scenarios: {
    browse: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: "1m", target: 20 },
        { duration: "3m", target: 60 },
        { duration: "1m", target: 0 },
      ],
      exec: "browse",
    },
    checkout: {
      executor: "constant-arrival-rate",
      rate: 2,
      timeUnit: "1s",
      duration: "5m",
      preAllocatedVUs: 5,
      exec: "checkout",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],               // SLO: 99% success
    http_req_duration: ["p(95)<500"],             // SLO: p95 < 500ms
  },
};

export function browse() {
  const r1 = http.get(`${BASE}/api/v1/products`);
  check(r1, { "products 200": (r) => r.status === 200 });
  http.get(`${BASE}/api/v1/stats`);
  sleep(Math.random() * 2);
}

export function checkout() {
  const product = 1 + Math.floor(Math.random() * 4);
  const r = http.post(
    `${BASE}/api/v1/orders`,
    JSON.stringify({ product_id: product, quantity: 1, customer_email: "load@cloudforge.dev" }),
    { headers: { "Content-Type": "application/json" } },
  );
  // 409 = out of stock: expected once seed stock is exhausted
  check(r, { "order 201/409": (res) => res.status === 201 || res.status === 409 });
}
