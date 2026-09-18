from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.cache import cache_delete, cache_get, cache_set
from app.db import get_session
from app.metrics import ORDER_REVENUE, ORDERS_CREATED
from app.models import Order, Product
from app.schemas import OrderIn, OrderOut, ProductIn, ProductOut, Stats

router = APIRouter(prefix="/api/v1", tags=["catalog"])

PRODUCTS_KEY = "products:all"
STATS_KEY = "stats:summary"


@router.get("/products", response_model=list[ProductOut])
async def list_products(session: AsyncSession = Depends(get_session)):
    if (cached := await cache_get(PRODUCTS_KEY)) is not None:
        return cached
    rows = (await session.scalars(select(Product).order_by(Product.id))).all()
    data = [ProductOut.model_validate(r).model_dump(mode="json") for r in rows]
    await cache_set(PRODUCTS_KEY, data)
    return data


@router.get("/products/{product_id}", response_model=ProductOut)
async def get_product(product_id: int, session: AsyncSession = Depends(get_session)):
    key = f"product:{product_id}"
    if (cached := await cache_get(key)) is not None:
        return cached
    product = await session.get(Product, product_id)
    if product is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "product not found")
    data = ProductOut.model_validate(product).model_dump(mode="json")
    await cache_set(key, data)
    return data


@router.post("/products", response_model=ProductOut, status_code=status.HTTP_201_CREATED)
async def create_product(body: ProductIn, session: AsyncSession = Depends(get_session)):
    product = Product(**body.model_dump())
    session.add(product)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "sku already exists") from exc
    await session.refresh(product)
    await cache_delete(PRODUCTS_KEY, STATS_KEY)
    return product


@router.post("/orders", response_model=OrderOut, status_code=status.HTTP_201_CREATED)
async def create_order(body: OrderIn, session: AsyncSession = Depends(get_session)):
    # SELECT ... FOR UPDATE prevents overselling under concurrent orders.
    product = await session.scalar(
        select(Product).where(Product.id == body.product_id).with_for_update()
    )
    if product is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "product not found")
    if product.stock < body.quantity:
        raise HTTPException(status.HTTP_409_CONFLICT, "insufficient stock")
    product.stock -= body.quantity
    order = Order(
        product_id=product.id,
        quantity=body.quantity,
        total_cents=product.price_cents * body.quantity,
        customer_email=body.customer_email,
    )
    session.add(order)
    await session.commit()
    await session.refresh(order)
    ORDERS_CREATED.labels(product=product.sku).inc()
    ORDER_REVENUE.inc(order.total_cents)
    await cache_delete(PRODUCTS_KEY, STATS_KEY, f"product:{product.id}")
    return order


@router.get("/orders", response_model=list[OrderOut])
async def list_orders(limit: int = 50, session: AsyncSession = Depends(get_session)):
    limit = max(1, min(limit, 200))
    rows = await session.scalars(select(Order).order_by(Order.id.desc()).limit(limit))
    return rows.all()


@router.get("/stats", response_model=Stats)
async def stats(session: AsyncSession = Depends(get_session)):
    if (cached := await cache_get(STATS_KEY)) is not None:
        return {**cached, "cached": True}
    products = await session.scalar(select(func.count(Product.id)))
    orders = await session.scalar(select(func.count(Order.id)))
    revenue = await session.scalar(select(func.coalesce(func.sum(Order.total_cents), 0)))
    data = {"products": products or 0, "orders": orders or 0, "revenue_cents": revenue or 0}
    await cache_set(STATS_KEY, data, ttl=15)
    return data
