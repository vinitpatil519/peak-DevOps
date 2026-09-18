from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class ProductIn(BaseModel):
    sku: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=200)
    description: str = ""
    price_cents: int = Field(ge=0)
    stock: int = Field(ge=0, default=0)


class ProductOut(ProductIn):
    model_config = ConfigDict(from_attributes=True)
    id: int
    created_at: datetime


class OrderIn(BaseModel):
    product_id: int
    quantity: int = Field(gt=0, le=100)
    customer_email: EmailStr


class OrderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    product_id: int
    quantity: int
    total_cents: int
    customer_email: str
    created_at: datetime


class Stats(BaseModel):
    products: int
    orders: int
    revenue_cents: int
    cached: bool = False
