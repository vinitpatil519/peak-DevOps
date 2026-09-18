async def _product(client, sku="SKU-1", stock=5):
    r = await client.post(
        "/api/v1/products",
        json={"sku": sku, "name": "Widget", "price_cents": 1999, "stock": stock},
    )
    assert r.status_code == 201, r.text
    return r.json()


async def test_healthz(client):
    r = await client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


async def test_readyz(client):
    r = await client.get("/readyz")
    assert r.status_code == 200
    assert r.json()["checks"]["database"] == "ok"


async def test_info(client):
    r = await client.get("/api/v1/info")
    assert r.json()["service"] == "cloudforge-api"


async def test_product_crud_and_cache(client):
    p = await _product(client)
    r1 = await client.get("/api/v1/products")
    r2 = await client.get("/api/v1/products")
    assert r1.json() == r2.json()
    assert r1.json()[0]["sku"] == p["sku"]
    r = await client.get(f"/api/v1/products/{p['id']}")
    assert r.json()["name"] == "Widget"


async def test_duplicate_sku(client):
    await _product(client)
    r = await client.post(
        "/api/v1/products", json={"sku": "SKU-1", "name": "Dup", "price_cents": 1}
    )
    assert r.status_code == 409


async def test_order_flow(client):
    p = await _product(client, stock=2)
    r = await client.post(
        "/api/v1/orders",
        json={"product_id": p["id"], "quantity": 2, "customer_email": "a@example.com"},
    )
    assert r.status_code == 201
    assert r.json()["total_cents"] == 3998
    r = await client.post(
        "/api/v1/orders",
        json={"product_id": p["id"], "quantity": 1, "customer_email": "a@example.com"},
    )
    assert r.status_code == 409
    stats = (await client.get("/api/v1/stats")).json()
    assert stats["orders"] == 1 and stats["revenue_cents"] == 3998
    assert len((await client.get("/api/v1/orders")).json()) == 1


async def test_invalid_order(client):
    r = await client.post(
        "/api/v1/orders", json={"product_id": 1, "quantity": 0, "customer_email": "bad"}
    )
    assert r.status_code == 422


async def test_missing_product(client):
    assert (await client.get("/api/v1/products/999")).status_code == 404


async def test_metrics_exposed(client):
    await client.get("/api/v1/info")
    r = await client.get("/metrics/")
    assert r.status_code == 200
    assert "http_requests_total" in r.text
